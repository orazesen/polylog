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

    // Output format: 0=JSON, 1=CSV, 2=TSV, 3=RAW
    static int output_format = 0;
    static int header_written = 0;
    static int output_fd = 1; // Default: stdout

    // Buffered output for efficiency (thread-safe)
    static char write_buffer[65536];
    static int buffer_pos = 0;
    static pthread_mutex_t output_lock = PTHREAD_MUTEX_INITIALIZER;

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

    static void do_flush()
    {
        if (buffer_pos > 0)
        {
            write(output_fd, write_buffer, buffer_pos);
            buffer_pos = 0;
        }
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

    void format_output(LogEntry *entry)
    {
        if (!entry->valid || !entry->filtered)
            return;

        const char *levels[] = {"DEBUG", "INFO", "WARN", "ERROR"};
        const char *level = (entry->level >= 0 && entry->level <= 3) ? levels[entry->level] : "UNKNOWN";

        pthread_mutex_lock(&output_lock);

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
        default:
            write_json(level, entry);
            break;
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
