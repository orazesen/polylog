// formatter.cpp - Multi-format output formatting (C++ component)
// Supports: JSON, JSONL, CSV, TSV, RAW formats
// Thread-safe with mutex protection

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>
#include <pthread.h>
#include <string.h>
#include "logentry.h"

extern "C"
{

    // Output format: 0=JSON, 1=CSV, 2=TSV, 3=RAW, 4=JSONL
    static int output_format = 0;
    static int header_written = 0;              // CSV/TSV header line, or the '[' opening the JSON array
    static int trailer_written = 0;             // finish_output() has already run
    static int write_failed = 0;                // A hard write error was already reported
    static int output_fd = 1;                   // Default: stdout
    static int split_mode = 0;                  // 0=single output, 1=split by level
    static int level_fds[4] = {-1, -1, -1, -1}; // FDs for DEBUG, INFO, WARN, ERROR

    // Buffered output for efficiency (thread-safe)
    static char write_buffer[65536];
    static int buffer_pos = 0;
    static pthread_mutex_t output_lock = PTHREAD_MUTEX_INITIALIZER;

    // Per-level buffers for split mode
    static char level_buffers[4][16384];
    static int level_buffer_pos[4] = {0, 0, 0, 0};

    // Room kept free for one record. The largest is JSON: 255 message bytes at
    // up to 6 output bytes each (\uXXXX) plus under 70 bytes of framing
    static const int RECORD_MAX = 2048;
    static const int MSG_MAX = 255;

    // Level labels, padded so that one fixed-size move copies any of them
    struct LevelName
    {
        char text[8];
        int len;
    };
    static const LevelName level_names[5] = {{"DEBUG", 5}, {"INFO", 4}, {"WARN", 4}, {"ERROR", 5}, {"UNKNOWN", 7}};

    // Set output format from C (any value outside 1-4 selects JSON)
    void set_output_format(int format)
    {
        output_format = (format >= 1 && format <= 4) ? format : 0;
    }

    // Set output file descriptor from C
    void set_output_fd(int fd)
    {
        output_fd = fd;
    }

    // Set per-level file descriptors for split mode
    void set_level_fds(int fd_debug, int fd_info, int fd_warn, int fd_err)
    {
        level_fds[0] = fd_debug;
        level_fds[1] = fd_info;
        level_fds[2] = fd_warn;
        level_fds[3] = fd_err;
        split_mode = 1;
    }

    // True for the error of a write to a closed pipe that SIGPIPE answers by
    // ending the process, as in 'logproc ... | head': no failure to report
    static int ends_by_sigpipe(int error)
    {
        struct sigaction action;
        return error == EPIPE && sigaction(SIGPIPE, NULL, &action) == 0 && action.sa_handler == SIG_DFL;
    }

    // write(2) may be short or interrupted; keep going until everything is out
    static void write_all(int fd, const char *buf, size_t len)
    {
        while (len > 0)
        {
            ssize_t n = write(fd, buf, len);
            if (n > 0)
            {
                buf += n;
                len -= (size_t)n;
                continue;
            }
            if (n < 0 && errno == EINTR)
                continue;
            if (n < 0 && errno == EAGAIN)
            {
                // Non-blocking descriptor (inherited pipe or tty): wait for room
                struct pollfd p = {fd, POLLOUT, 0};
                poll(&p, 1, -1);
                continue;
            }
            // Nothing more can be done with this descriptor; say so once
            int error = n < 0 ? errno : 0;
            if (!write_failed)
            {
                static const char msg[] = "Error: write failed, output is incomplete\n";
                write_failed = 1;
                if (!ends_by_sigpipe(error))
                    write_all(2, msg, sizeof(msg) - 1);
            }
            return;
        }
    }

    static void flush_level(int level)
    {
        if (level_buffer_pos[level] > 0 && level_fds[level] >= 0)
            write_all(level_fds[level], level_buffers[level], level_buffer_pos[level]);
        level_buffer_pos[level] = 0;
    }

    static void do_flush()
    {
        if (buffer_pos > 0)
        {
            write_all(output_fd, write_buffer, buffer_pos);
            buffer_pos = 0;
        }
        // Flush level buffers if in split mode
        if (split_mode)
        {
            for (int i = 0; i < 4; i++)
                flush_level(i);
        }
    }

    // Where the next len bytes of a level file go (split mode); flushes to make room
    static char *level_buffer_room(int level, int len)
    {
        if (level_buffer_pos[level] + len > (int)sizeof(level_buffers[level]))
            flush_level(level);
        return level_buffers[level] + level_buffer_pos[level];
    }

    // Where the next len bytes of the main output go; flushes to make room
    static char *buffer_room(int len)
    {
        if (buffer_pos + len > (int)sizeof(write_buffer))
            do_flush();
        return write_buffer + buffer_pos;
    }

    static void buffer_str(const char *str)
    {
        int len = (int)strlen(str);
        memcpy(buffer_room(len), str, len);
        buffer_pos += len;
    }

    // The put_* and write_* helpers below format straight into buffer room and
    // return the new end; they never write more than RECORD_MAX bytes

    static char *put_str(char *out, const char *str)
    {
        size_t len = strlen(str);
        memcpy(out, str, len);
        return out + len;
    }

    static char *put_level(char *out, const LevelName *level)
    {
        // All 8 bytes are moved; those past len land in room that is still free
        memcpy(out, level->text, sizeof(level->text));
        return out + level->len;
    }

    // Decimal timestamp; negated as unsigned so the most negative value is safe
    static char *put_timestamp(char *out, long long ts)
    {
        unsigned long long u = (unsigned long long)ts;
        if (ts < 0)
        {
            *out++ = '-';
            u = 0 - u;
        }
        char tmp[20];
        int tmp_len = 0;
        do
        {
            tmp[tmp_len++] = '0' + (char)(u % 10);
            u /= 10;
        } while (u > 0);
        while (tmp_len > 0)
            *out++ = tmp[--tmp_len];
        return out;
    }

    static int is_cont(unsigned char c)
    {
        return (c & 0xC0) == 0x80;
    }

    // Length of the well-formed UTF-8 sequence starting at s, or 0 if there is
    // none (stray or missing continuation, overlong form, surrogate, > U+10FFFF)
    static int utf8_sequence(const unsigned char *s, int avail)
    {
        unsigned char c = s[0];
        if (c >= 0xC2 && c <= 0xDF)
        {
            return (avail >= 2 && is_cont(s[1])) ? 2 : 0;
        }
        if (c >= 0xE0 && c <= 0xEF)
        {
            if (avail < 3 || !is_cont(s[1]) || !is_cont(s[2]))
                return 0;
            if ((c == 0xE0 && s[1] < 0xA0) || (c == 0xED && s[1] > 0x9F))
                return 0;
            return 3;
        }
        if (c >= 0xF0 && c <= 0xF4)
        {
            if (avail < 4 || !is_cont(s[1]) || !is_cont(s[2]) || !is_cont(s[3]))
                return 0;
            if ((c == 0xF0 && s[1] < 0x90) || (c == 0xF4 && s[1] > 0x8F))
                return 0;
            return 4;
        }
        return 0;
    }

    // Body of a JSON string. The result is always valid JSON and valid UTF-8:
    // each byte outside a well-formed sequence becomes the escape for U+FFFD
    static char *put_json_string(char *out, const char *str, int len)
    {
        static const char hex[] = "0123456789abcdef";
        const unsigned char *s = (const unsigned char *)str;
        int i = 0;
        while (i < len)
        {
            unsigned char c = s[i];
            if (c >= 0x20 && c < 0x80)
            {
                if (c == '"' || c == '\\')
                    *out++ = '\\';
                *out++ = (char)c;
                i++;
            }
            else if (c >= 0x80)
            {
                int seq = utf8_sequence(s + i, len - i);
                if (seq > 0)
                {
                    memcpy(out, s + i, seq);
                    out += seq;
                    i += seq;
                }
                else
                {
                    out = put_str(out, "\\ufffd");
                    i++;
                }
            }
            else
            {
                *out++ = '\\';
                switch (c)
                {
                case '\b':
                    *out++ = 'b';
                    break;
                case '\f':
                    *out++ = 'f';
                    break;
                case '\n':
                    *out++ = 'n';
                    break;
                case '\r':
                    *out++ = 'r';
                    break;
                case '\t':
                    *out++ = 't';
                    break;
                default:
                    *out++ = 'u';
                    *out++ = '0';
                    *out++ = '0';
                    *out++ = hex[c >> 4];
                    *out++ = hex[c & 15];
                    break;
                }
                i++;
            }
        }
        return out;
    }

    // One JSON object without a line ending (shared by the JSON and JSONL formats)
    static char *write_json_object(char *out, const LevelName *level, const LogEntry *entry, int msg_len)
    {
        out = put_str(out, "{\"level\":\"");
        out = put_level(out, level);
        out = put_str(out, "\",\"timestamp\":");
        out = put_timestamp(out, entry->timestamp);
        out = put_str(out, ",\"message\":\"");
        out = put_json_string(out, entry->msg, msg_len);
        return put_str(out, "\"}");
    }

    static char *write_csv(char *out, const LevelName *level, const LogEntry *entry, int msg_len)
    {
        out = put_level(out, level);
        *out++ = ',';
        out = put_timestamp(out, entry->timestamp);
        *out++ = ',';
        *out++ = '"';
        for (int i = 0; i < msg_len; i++)
        {
            char c = entry->msg[i];
            if (c == '"')
                *out++ = '"'; // Escape quotes by doubling
            *out++ = c;
        }
        *out++ = '"';
        *out++ = '\n';
        return out;
    }

    static char *write_tsv(char *out, const LevelName *level, const LogEntry *entry, int msg_len)
    {
        out = put_level(out, level);
        *out++ = '\t';
        out = put_timestamp(out, entry->timestamp);
        *out++ = '\t';
        // Escape the separators so a row always has exactly three fields
        for (int i = 0; i < msg_len; i++)
        {
            char c = entry->msg[i];
            // Common case first: above '\r' only the backslash is escaped
            if ((unsigned char)c > '\r' && c != '\\')
            {
                *out++ = c;
                continue;
            }
            char esc = c == '\\' ? '\\' : c == '\t' ? 't' : c == '\n' ? 'n' : c == '\r' ? 'r' : 0;
            if (esc)
            {
                *out++ = '\\';
                *out++ = esc;
            }
            else
            {
                *out++ = c;
            }
        }
        *out++ = '\n';
        return out;
    }

    static char *write_raw(char *out, const LevelName *level, const LogEntry *entry, int msg_len)
    {
        *out++ = '[';
        out = put_level(out, level);
        out = put_str(out, "] ");
        memcpy(out, entry->msg, msg_len);
        out += msg_len;
        *out++ = '\n';
        return out;
    }

    void format_output(LogEntry *entry)
    {
        if (!entry->valid || !entry->filtered)
            return;

        int known_level = entry->level >= 0 && entry->level <= 3;
        const LevelName *level = &level_names[known_level ? entry->level : 4];

        // RECORD_MAX relies on this bound
        int msg_len = entry->msg_len;
        if (msg_len < 0)
            msg_len = 0;
        if (msg_len > MSG_MAX)
            msg_len = MSG_MAX;

        pthread_mutex_lock(&output_lock);

        // Split mode: write to per-level files
        if (split_mode && known_level)
        {
            char *start = level_buffer_room(entry->level, RECORD_MAX);
            char *end = write_raw(start, level, entry, msg_len);
            level_buffer_pos[entry->level] += (int)(end - start);
        }
        else
        {
            char *out = buffer_room(RECORD_MAX);
            switch (output_format)
            {
            case 1:
                if (!header_written)
                    out = put_str(out, "level,timestamp,message\n");
                out = write_csv(out, level, entry, msg_len);
                break;
            case 2:
                if (!header_written)
                    out = put_str(out, "level\ttimestamp\tmessage\n");
                out = write_tsv(out, level, entry, msg_len);
                break;
            case 3:
                out = write_raw(out, level, entry, msg_len);
                break;
            case 4:
                out = write_json_object(out, level, entry, msg_len);
                *out++ = '\n';
                break;
            default:
                // One array: finish_output() writes the closing bracket
                *out++ = header_written ? ',' : '[';
                *out++ = '\n';
                out = write_json_object(out, level, entry, msg_len);
                break;
            }
            header_written = 1;
            buffer_pos = (int)(out - write_buffer);
        }

        pthread_mutex_unlock(&output_lock);
    }

    void flush_buffer()
    {
        pthread_mutex_lock(&output_lock);
        do_flush();
        pthread_mutex_unlock(&output_lock);
    }

    // End of a normal run: write the format trailer (only JSON has one, the
    // closing of its array) and flush everything
    void finish_output(void)
    {
        pthread_mutex_lock(&output_lock);
        if (!trailer_written && output_format == 0)
        {
            if (header_written)
                buffer_str("\n]\n");
            else if (!split_mode) // Split mode writes no JSON document at all
                buffer_str("[]\n");
        }
        trailer_written = 1;
        do_flush();
        pthread_mutex_unlock(&output_lock);
    }

    // 1 once a hard write error has lost output; the reader turns that into
    // its exit status
    int output_failed(void)
    {
        pthread_mutex_lock(&output_lock);
        int failed = write_failed;
        pthread_mutex_unlock(&output_lock);
        return failed;
    }

} // extern "C"
