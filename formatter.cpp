// formatter.cpp - Multi-format output formatting (C++ component)
// Supports: JSON, CSV, TSV, RAW formats
// Thread-safe with mutex protection

#include <unistd.h>
#include <pthread.h>
#include <string.h>

extern "C"
{

    struct LogEntry
    {
        int level;
        int valid;
        int filtered; // 1=should output, 0=filtered out
        int msg_len;
        long long timestamp; // Unix timestamp
        char msg[256];
    };

    // Output format: 0=JSON, 1=CSV, 2=TSV, 3=RAW, 4=JSONL
    static int output_format = 0;
    static int header_written = 0;
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

    // Set output format from C
    void set_output_format(int format)
    {
        output_format = format;
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

    static void do_flush()
    {
        if (buffer_pos > 0)
        {
            write(output_fd, write_buffer, buffer_pos);
            buffer_pos = 0;
        }
        // Flush level buffers if in split mode
        if (split_mode)
        {
            for (int i = 0; i < 4; i++)
            {
                if (level_buffer_pos[i] > 0 && level_fds[i] >= 0)
                {
                    write(level_fds[i], level_buffers[i], level_buffer_pos[i]);
                    level_buffer_pos[i] = 0;
                }
            }
        }
    }

    // Write to level-specific buffer (for split mode)
    static void level_buffer_write(int level, const char *str, int len)
    {
        if (level < 0 || level > 3)
            return;
        if (level_buffer_pos[level] + len >= 16384)
        {
            write(level_fds[level], level_buffers[level], level_buffer_pos[level]);
            level_buffer_pos[level] = 0;
        }
        for (int i = 0; i < len; i++)
        {
            level_buffers[level][level_buffer_pos[level]++] = str[i];
        }
    }

    static void level_buffer_str(int level, const char *str)
    {
        level_buffer_write(level, str, strlen(str));
    }

    static void level_buffer_char(int level, char c)
    {
        if (level < 0 || level > 3)
            return;
        if (level_buffer_pos[level] >= 16383)
        {
            write(level_fds[level], level_buffers[level], level_buffer_pos[level]);
            level_buffer_pos[level] = 0;
        }
        level_buffers[level][level_buffer_pos[level]++] = c;
    }

    static void buffer_write(const char *str, int len)
    {
        if (buffer_pos + len >= 65536)
        {
            do_flush();
        }
        for (int i = 0; i < len; i++)
        {
            write_buffer[buffer_pos++] = str[i];
        }
    }

    static void buffer_str(const char *str)
    {
        buffer_write(str, strlen(str));
    }

    static void buffer_char(char c)
    {
        if (buffer_pos >= 65535)
        {
            do_flush();
        }
        write_buffer[buffer_pos++] = c;
    }

    static void write_json(const char *level, LogEntry *entry)
    {
        buffer_write("{\"level\":\"", 10);
        buffer_str(level);
        buffer_write("\",\"timestamp\":", 14);
        char ts_buf[24];
        int ts_len = 0;
        long long ts = entry->timestamp;
        if (ts == 0)
        {
            ts_buf[ts_len++] = '0';
        }
        else
        {
            char tmp[24];
            int tmp_len = 0;
            while (ts > 0)
            {
                tmp[tmp_len++] = '0' + (ts % 10);
                ts /= 10;
            }
            while (tmp_len > 0)
                ts_buf[ts_len++] = tmp[--tmp_len];
        }
        buffer_write(ts_buf, ts_len);
        buffer_write(",\"message\":\"", 13);
        for (int i = 0; i < entry->msg_len; i++)
        {
            char c = entry->msg[i];
            if (c == '"' || c == '\\')
                buffer_char('\\');
            buffer_char(c);
        }
        buffer_write("\"}\n", 3);
    }

    static void write_csv(const char *level, LogEntry *entry)
    {
        if (!header_written)
        {
            buffer_str("level,timestamp,message\n");
            header_written = 1;
        }
        buffer_str(level);
        buffer_char(',');
        // Write timestamp
        char ts_buf[24];
        int ts_len = 0;
        long long ts = entry->timestamp;
        if (ts == 0)
        {
            ts_buf[ts_len++] = '0';
        }
        else
        {
            char tmp[24];
            int tmp_len = 0;
            while (ts > 0)
            {
                tmp[tmp_len++] = '0' + (ts % 10);
                ts /= 10;
            }
            while (tmp_len > 0)
                ts_buf[ts_len++] = tmp[--tmp_len];
        }
        buffer_write(ts_buf, ts_len);
        buffer_str(",\"");
        ;
        for (int i = 0; i < entry->msg_len; i++)
        {
            char c = entry->msg[i];
            if (c == '"')
                buffer_char('"'); // Escape quotes by doubling
            buffer_char(c);
        }
        buffer_str("\"\n");
    }

    static void write_tsv(const char *level, LogEntry *entry)
    {
        if (!header_written)
        {
            buffer_str("level\ttimestamp\tmessage\n");
            header_written = 1;
        }
        buffer_str(level);
        buffer_char('\t');
        // Write timestamp
        char ts_buf[24];
        int ts_len = 0;
        long long ts = entry->timestamp;
        if (ts == 0)
        {
            ts_buf[ts_len++] = '0';
        }
        else
        {
            char tmp[24];
            int tmp_len = 0;
            while (ts > 0)
            {
                tmp[tmp_len++] = '0' + (ts % 10);
                ts /= 10;
            }
            while (tmp_len > 0)
                ts_buf[ts_len++] = tmp[--tmp_len];
        }
        buffer_write(ts_buf, ts_len);
        buffer_char('\t');
        buffer_write(entry->msg, entry->msg_len);
        buffer_char('\n');
    }

    static void write_raw(const char *level, LogEntry *entry)
    {
        buffer_char('[');
        buffer_str(level);
        buffer_str("] ");
        buffer_write(entry->msg, entry->msg_len);
        buffer_char('\n');
    }

    // JSON Lines format (one JSON object per line, no trailing array)
    static void write_jsonl(const char *level, LogEntry *entry)
    {
        buffer_write("{\"level\":\"", 10);
        buffer_str(level);
        buffer_write("\",\"timestamp\":", 14);
        char ts_buf[24];
        int ts_len = 0;
        long long ts = entry->timestamp;
        if (ts == 0)
        {
            ts_buf[ts_len++] = '0';
        }
        else
        {
            char tmp[24];
            int tmp_len = 0;
            while (ts > 0)
            {
                tmp[tmp_len++] = '0' + (ts % 10);
                ts /= 10;
            }
            while (tmp_len > 0)
                ts_buf[ts_len++] = tmp[--tmp_len];
        }
        buffer_write(ts_buf, ts_len);
        buffer_write(",\"message\":\"", 13);
        for (int i = 0; i < entry->msg_len; i++)
        {
            char c = entry->msg[i];
            if (c == '"' || c == '\\')
                buffer_char('\\');
            buffer_char(c);
        }
        buffer_write("\"}\n", 3);
    }

    // Write to level-specific file (split mode)
    static void write_split_raw(LogEntry *entry)
    {
        const char *levels[] = {"DEBUG", "INFO", "WARN", "ERROR"};
        int lvl = entry->level;
        if (lvl < 0 || lvl > 3)
            return;

        level_buffer_char(lvl, '[');
        level_buffer_str(lvl, levels[lvl]);
        level_buffer_str(lvl, "] ");
        level_buffer_write(lvl, entry->msg, entry->msg_len);
        level_buffer_char(lvl, '\n');
    }

    void format_output(LogEntry *entry)
    {
        if (!entry->valid || !entry->filtered)
            return;

        const char *levels[] = {"DEBUG", "INFO", "WARN", "ERROR"};
        const char *level = (entry->level >= 0 && entry->level <= 3) ? levels[entry->level] : "UNKNOWN";

        pthread_mutex_lock(&output_lock);

        // Split mode: write to per-level files
        if (split_mode && entry->level >= 0 && entry->level <= 3)
        {
            write_split_raw(entry);
        }
        else
        {
            switch (output_format)
            {
            case 1:
                write_csv(level, entry);
                break;
            case 2:
                write_tsv(level, entry);
                break;
            case 3:
                write_raw(level, entry);
                break;
            case 4:
                write_jsonl(level, entry);
                break;
            default:
                write_json(level, entry);
                break;
            }
        }

        pthread_mutex_unlock(&output_lock);
    }

    void flush_buffer()
    {
        pthread_mutex_lock(&output_lock);
        do_flush();
        pthread_mutex_unlock(&output_lock);
    }

} // extern "C"
