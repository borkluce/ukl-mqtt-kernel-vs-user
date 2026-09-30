/* Subscriber logger for one run. Runs on the host, pinned to its own core.
 *
 * usage: mqtt-subscriber <broker_ip> <run_id> <out_dir> [--count-only]
 *
 * Subscribes to the publisher topic and to the broker's $SYS publish counters, and keeps
 * all records in memory until SIGINT/SIGTERM, then writes them to <out_dir>:
 *   summary.txt  counts: received, for this run, other runs, unique seq, missing, duplicates,
 *                out-of-order, first/last arrival, broker $SYS counters at start and end,
 *                subscriber CPU time
 *   per_ms.csv   messages of this run arriving in each millisecond after the first arrival
 *   gaps.csv     every gap of >= 1 ms between consecutive arrivals, with the seq around it
 * --count-only keeps only the counters (used in the pilot to check that the full logging
 * does not slow the subscriber down).
 * Arrival times are CLOCK_MONOTONIC on the host; they are only compared with each other.
 */
#define _GNU_SOURCE
#include <mosquitto.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#define TOPIC       "iot/sensor"
#define SYS_TOPIC   "$SYS/broker/publish/messages/#"
#define MAX_MS      600000          /* 10 minutes of per-ms bins */
#define SEQ_BITS    (1u << 27)      /* 134M sequence numbers, 16 MB bitmap */
#define MAX_GAPS    100000
#define GAP_NS      1000000LL       /* 1 ms */

struct gap { long long at_ms_x1000; long long gap_us; long seq_before, seq_after; };

static volatile sig_atomic_t stop;
static const char *run_id;
static size_t run_id_len;
static int count_only;

static long long received, for_run, other_run, unparsable;
static long long first_ns, last_ns, prev_ns;
static long long unique, duplicates, backwards, seq_overflow, max_seq = -1, last_seq = -1;
static uint32_t *per_ms;
static uint8_t *seen;
static struct gap *gaps;
static long n_gaps, gaps_dropped;

struct sysval { long long first, last; int have; };
static struct sysval sys_received, sys_sent, sys_dropped;

static long long now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}

static void on_signal(int sig) { (void)sig; stop = 1; }

static void sys_update(struct sysval *v, const char *payload, int len) {
    char buf[32];
    int n = len < 31 ? len : 31;
    memcpy(buf, payload, n);
    buf[n] = 0;
    long long x = atoll(buf);
    if (!v->have) { v->first = x; v->have = 1; }
    v->last = x;
}

static void on_message(struct mosquitto *m, void *ud, const struct mosquitto_message *msg) {
    (void)m; (void)ud;
    if (msg->topic[0] == '$') {
        const char *t = msg->topic + strlen("$SYS/broker/publish/messages/");
        if (strcmp(t, "received") == 0) sys_update(&sys_received, msg->payload, msg->payloadlen);
        else if (strcmp(t, "sent") == 0) sys_update(&sys_sent, msg->payload, msg->payloadlen);
        else if (strcmp(t, "dropped") == 0) sys_update(&sys_dropped, msg->payload, msg->payloadlen);
        return;
    }

    long long t = now_ns();
    received++;
    if (!first_ns) first_ns = t;
    last_ns = t;

    /* payload: {"run":"<id>","seq":<n>,...} */
    const char *p = msg->payload;
    int len = msg->payloadlen;
    if (len < 9 || memcmp(p, "{\"run\":\"", 8) != 0) { unparsable++; return; }
    p += 8; len -= 8;
    if ((size_t)len <= run_id_len || memcmp(p, run_id, run_id_len) != 0 || p[run_id_len] != '"') {
        other_run++;
        return;
    }
    for_run++;
    if (count_only) return;

    p += run_id_len; len -= (int)run_id_len;
    if (len < 8 || memcmp(p, "\",\"seq\":", 8) != 0) { unparsable++; return; }
    p += 8;
    long seq = 0;
    while (*p >= '0' && *p <= '9') seq = seq * 10 + (*p++ - '0');

    long long ms = (t - first_ns) / 1000000LL;
    if (ms < MAX_MS) per_ms[ms]++;

    if ((unsigned long)seq < SEQ_BITS) {
        uint8_t bit = (uint8_t)(1u << (seq & 7));
        if (seen[seq >> 3] & bit) duplicates++;
        else { seen[seq >> 3] |= bit; unique++; }
    } else {
        seq_overflow++;
    }
    if (seq < last_seq) backwards++;
    if (seq > max_seq) max_seq = seq;

    if (prev_ns && t - prev_ns >= GAP_NS) {
        if (n_gaps < MAX_GAPS) {
            gaps[n_gaps].at_ms_x1000 = (prev_ns - first_ns) / 1000;
            gaps[n_gaps].gap_us = (t - prev_ns) / 1000;
            gaps[n_gaps].seq_before = last_seq;
            gaps[n_gaps].seq_after = seq;
            n_gaps++;
        } else {
            gaps_dropped++;
        }
    }
    prev_ns = t;
    last_seq = seq;
}

static FILE *open_out(const char *dir, const char *name) {
    char path[4096];
    snprintf(path, sizeof(path), "%s/%s", dir, name);
    FILE *f = fopen(path, "w");
    if (!f) { perror(path); exit(1); }
    return f;
}

int main(int argc, char *argv[]) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <broker_ip> <run_id> <out_dir> [--count-only]\n", argv[0]);
        return 2;
    }
    const char *broker = argv[1], *out_dir = argv[3];
    run_id = argv[2];
    run_id_len = strlen(run_id);
    count_only = (argc > 4 && strcmp(argv[4], "--count-only") == 0);

    if (!count_only) {
        per_ms = calloc(MAX_MS, sizeof(*per_ms));
        seen = calloc(SEQ_BITS / 8, 1);
        gaps = calloc(MAX_GAPS, sizeof(*gaps));
        if (!per_ms || !seen || !gaps) { fprintf(stderr, "out of memory\n"); return 1; }
    }

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    mosquitto_lib_init();
    struct mosquitto *m = mosquitto_new("sub-logger", true, NULL);
    if (!m) { fprintf(stderr, "mosquitto_new failed\n"); return 1; }
    mosquitto_message_callback_set(m, on_message);
    if (mosquitto_connect(m, broker, 1883, 60) != MOSQ_ERR_SUCCESS) {
        fprintf(stderr, "connect to %s failed\n", broker);
        return 1;
    }
    mosquitto_subscribe(m, NULL, TOPIC, 0);
    mosquitto_subscribe(m, NULL, SYS_TOPIC, 0);
    printf("SUBSCRIBER_READY run_id=%s mode=%s\n", run_id, count_only ? "count-only" : "full");
    fflush(stdout);

    while (!stop) {
        int rc = mosquitto_loop(m, 100, 1);
        if (rc != MOSQ_ERR_SUCCESS && !stop) {
            fprintf(stderr, "mosquitto_loop: %s\n", mosquitto_strerror(rc));
            break;
        }
    }
    mosquitto_disconnect(m);
    mosquitto_destroy(m);
    mosquitto_lib_cleanup();

    struct rusage ru;
    getrusage(RUSAGE_SELF, &ru);
    double cpu_s = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec / 1e6 +
                   ru.ru_stime.tv_sec + ru.ru_stime.tv_usec / 1e6;

    FILE *f = open_out(out_dir, "summary.txt");
    fprintf(f, "run_id=%s\nmode=%s\n", run_id, count_only ? "count-only" : "full");
    fprintf(f, "received_total=%lld\nreceived_this_run=%lld\nreceived_other_runs=%lld\nunparsable=%lld\n",
            received, for_run, other_run, unparsable);
    fprintf(f, "arrival_span_us=%lld\n", first_ns ? (last_ns - first_ns) / 1000 : 0);
    if (!count_only) {
        fprintf(f, "unique_seq=%lld\nmax_seq=%lld\nmissing_up_to_max_seq=%lld\n",
                unique, max_seq, max_seq >= 0 ? (max_seq + 1) - unique : 0);
        fprintf(f, "duplicates=%lld\nseq_backwards=%lld\nseq_overflow=%lld\n",
                duplicates, backwards, seq_overflow);
        fprintf(f, "gaps_ge_1ms=%ld\ngaps_dropped=%ld\n", n_gaps, gaps_dropped);
    }
    fprintf(f, "broker_received_start=%lld\nbroker_received_end=%lld\n", sys_received.first, sys_received.last);
    fprintf(f, "broker_sent_start=%lld\nbroker_sent_end=%lld\n", sys_sent.first, sys_sent.last);
    fprintf(f, "broker_dropped_start=%lld\nbroker_dropped_end=%lld\n", sys_dropped.first, sys_dropped.last);
    fprintf(f, "subscriber_cpu_s=%.3f\n", cpu_s);
    fclose(f);

    if (!count_only) {
        long last = -1;
        for (long i = 0; i < MAX_MS; i++) if (per_ms[i]) last = i;
        f = open_out(out_dir, "per_ms.csv");
        fprintf(f, "ms,messages\n");
        for (long i = 0; i <= last; i++) fprintf(f, "%ld,%u\n", i, per_ms[i]);
        fclose(f);

        f = open_out(out_dir, "gaps.csv");
        fprintf(f, "at_us,gap_us,seq_before,seq_after\n");
        for (long i = 0; i < n_gaps; i++)
            fprintf(f, "%lld,%lld,%ld,%ld\n", gaps[i].at_ms_x1000, gaps[i].gap_us,
                    gaps[i].seq_before, gaps[i].seq_after);
        fclose(f);
    }
    printf("SUBSCRIBER_DONE run_id=%s received_this_run=%lld\n", run_id, for_run);
    return 0;
}
