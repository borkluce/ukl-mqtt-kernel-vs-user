/* MQTT throughput benchmark publisher (fixed-time window), instrumented.
 *
 * Built twice from this file: embedded in the UKL kernel (configuration 4) and as a
 * static user-space binary (configurations 1-3). The publish loop is the thesis loop;
 * changes are measurement only:
 *   - run ID taken from argv[1] and carried in every payload next to the sequence number
 *   - publishes accepted inside the 30 s window counted separately from the final drain
 *   - per-second accepted counts, buffer-full periods and mqtt_sync errors recorded in
 *     memory during the window and printed only after it, so logging does not touch
 *     the measured period
 *   - MQTT connect/handshake timed separately (it is outside the window)
 *   - loop mode from argv[2]:
 *       thesis  (default) the thesis loop unchanged. MQTT-C keeps MQTT_ERROR_SEND_BUFFER_IS_FULL
 *               in client.error once set and mqtt_publish returns it without retrying, so the
 *               first buffer-full event stops publishing for the rest of the window.
 *       recover identical, except that after each mqtt_sync a buffer-full error is cleared,
 *               so publishing resumes once the queue has drained. Every buffer-full period
 *               is still recorded.
 * The "done, idling" line stays last: the launcher stops QEMU when it sees it.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#include "mqtt.h"

#ifndef BROKER_ADDR
#define BROKER_ADDR "192.168.150.1"
#endif
#define BROKER_PORT     1883
#define TOPIC           "iot/sensor"
#ifndef CLIENT_ID
#define CLIENT_ID       "ukl-publisher"
#endif
#ifndef DURATION_SEC
#define DURATION_SEC    30
#endif
#define DRAIN_SYNCS     200         /* same final drain as the thesis */
#define MAX_FULL_EVENTS 4096
#define MAX_SYNC_ERRORS 1024
#define MAX_SECONDS     (DURATION_SEC + 1)
#define LOG             "UKL-MQTT-BENCH: "

static uint8_t sendbuf[65536];
static uint8_t recvbuf[4096];

/* In-memory records, printed after the window. Times are ns since the window start. */
struct full_event { long long start_ns, end_ns; };
struct sync_error { long long t_ns; int code; int phase; };   /* phase 0 = window, 1 = drain */

static struct full_event full_events[MAX_FULL_EVENTS];
static struct sync_error sync_errors[MAX_SYNC_ERRORS];
static long accepted_per_second[MAX_SECONDS];
static int n_full_events, n_sync_errors;
static long full_events_dropped, sync_errors_dropped;

static int connect_broker(const char *addr, int port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    struct sockaddr_in srv;
    memset(&srv, 0, sizeof(srv));
    srv.sin_family = AF_INET;
    srv.sin_port = htons(port);
    if (inet_pton(AF_INET, addr, &srv.sin_addr) <= 0) { close(s); return -1; }
    if (connect(s, (struct sockaddr *)&srv, sizeof(srv)) < 0) { close(s); return -1; }
    int fl = fcntl(s, F_GETFL, 0);
    if (fl < 0 || fcntl(s, F_SETFL, fl | O_NONBLOCK) < 0) { close(s); return -1; }
    return s;
}

static long long ns_since(struct timespec a, struct timespec b) {
    return (long long)(b.tv_sec - a.tv_sec) * 1000000000LL + (b.tv_nsec - a.tv_nsec);
}

static void record_sync_error(long long t_ns, int code, int phase) {
    if (n_sync_errors < MAX_SYNC_ERRORS) {
        sync_errors[n_sync_errors].t_ns = t_ns;
        sync_errors[n_sync_errors].code = code;
        sync_errors[n_sync_errors].phase = phase;
        n_sync_errors++;
    } else {
        sync_errors_dropped++;
    }
}

static void idle_forever(void) {
#ifndef BENCHMARK_EXIT
    for (;;) pause();
#endif
}

int main(int argc, char *argv[]) {
    const char *run_id = (argc > 1 && argv[1][0]) ? argv[1] : "none";
    const int recover = (argc > 2 && strcmp(argv[2], "recover") == 0);
    printf(LOG "starting, run_id=%s loop=%s duration=%d sec\n",
           run_id, recover ? "recover" : "thesis", DURATION_SEC);

    struct timespec t_conn0, t_conn1;
    clock_gettime(CLOCK_MONOTONIC, &t_conn0);

    int sock = connect_broker(BROKER_ADDR, BROKER_PORT);
    if (sock < 0) {
        printf(LOG "connect failed\n");
        printf(LOG "done, idling\n");
        idle_forever();
        return 1;
    }

    struct mqtt_client client;
    mqtt_init(&client, sock, sendbuf, sizeof(sendbuf),
              recvbuf, sizeof(recvbuf), NULL);
    mqtt_connect(&client, CLIENT_ID, NULL, NULL, 0, NULL, NULL,
                 MQTT_CONNECT_CLEAN_SESSION, 400);

    /* drive CONNACK (unchanged from the thesis) */
    for (int t = 0; t < 100; t++) {
        mqtt_sync(&client);
        if (client.error != MQTT_OK && client.error != MQTT_ERROR_SEND_BUFFER_IS_FULL) {
            printf(LOG "mqtt connect error=%d\n", client.error);
            printf(LOG "done, idling\n");
            idle_forever();
            return 1;
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &t_conn1);
    printf(LOG "broker connected, connect_us=%lld, running for %d sec\n",
           ns_since(t_conn0, t_conn1) / 1000, DURATION_SEC);

    char payload[160];
    struct timespec t_start, t_now;
    long accepted = 0, attempts = 0, full_returns = 0;
    long long payload_bytes = 0;
    int payload_min = 1 << 30, payload_max = 0;
    int in_full = 0, stopped_on_error = 0, stop_code = 0;
    long i = 0;
    long long now_ns = 0;
    const long long window_ns = (long long)DURATION_SEC * 1000000000LL;

    clock_gettime(CLOCK_MONOTONIC, &t_start);
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &t_now);
        now_ns = ns_since(t_start, t_now);
        if (now_ns >= window_ns) break;

        int len = snprintf(payload, sizeof(payload),
                           "{\"run\":\"%s\",\"seq\":%ld,\"temp\":%ld,\"humidity\":%ld}",
                           run_id, i, 20 + (i % 10), 50 + (i % 30));

        attempts++;
        enum MQTTErrors rc = mqtt_publish(&client, TOPIC, payload, len,
                                          MQTT_PUBLISH_QOS_0);
        if (rc == MQTT_OK) {
            if (in_full) {
                full_events[n_full_events - 1].end_ns = now_ns;
                in_full = 0;
            }
            accepted++;
            accepted_per_second[now_ns / 1000000000LL]++;
            payload_bytes += len;
            if (len < payload_min) payload_min = len;
            if (len > payload_max) payload_max = len;
            i++;
        } else if (rc == MQTT_ERROR_SEND_BUFFER_IS_FULL) {
            full_returns++;
            if (!in_full) {
                if (n_full_events < MAX_FULL_EVENTS) {
                    full_events[n_full_events].start_ns = now_ns;
                    full_events[n_full_events].end_ns = -1;
                    n_full_events++;
                    in_full = 1;
                } else {
                    full_events_dropped++;
                }
            }
        } else {
            stopped_on_error = 1;
            stop_code = rc;
            break;
        }
        /* drive both send and receive */
        enum MQTTErrors src = mqtt_sync(&client);
        if (src != MQTT_OK) record_sync_error(now_ns, src, 0);
        if (recover && client.error == MQTT_ERROR_SEND_BUFFER_IS_FULL) client.error = MQTT_OK;
    }
    long long window_end_ns = now_ns;
    if (in_full) full_events[n_full_events - 1].end_ns = window_end_ns;   /* still full at window end */

    /* final drain: same 200 syncs as the thesis, now timed and reported separately */
    struct timespec t_d0, t_d1;
    clock_gettime(CLOCK_MONOTONIC, &t_d0);
    long drain_errors = 0;
    for (int j = 0; j < DRAIN_SYNCS; j++) {
        enum MQTTErrors src = mqtt_sync(&client);
        if (src != MQTT_OK) {
            drain_errors++;
            clock_gettime(CLOCK_MONOTONIC, &t_now);
            record_sync_error(ns_since(t_start, t_now), src, 1);
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &t_d1);

    long unsent_after_drain = 0;
    for (ssize_t k = 0; k < mqtt_mq_length(&client.mq); k++) {
        if (mqtt_mq_get(&client.mq, k)->state == MQTT_QUEUED_UNSENT) unsent_after_drain++;
    }

    /* ---- report (everything below is outside the measured window) ---- */
    double window_s = window_end_ns / 1e9;
    printf(LOG "WINDOW run_id=%s loop=%s accepted=%ld attempts=%ld buffer_full_returns=%ld "
           "window_ns=%lld payload_bytes=%lld payload_min=%d payload_max=%d "
           "stopped_on_error=%d stop_code=%d\n",
           run_id, recover ? "recover" : "thesis", accepted, attempts, full_returns, window_end_ns, payload_bytes,
           accepted ? payload_min : 0, payload_max, stopped_on_error, stop_code);
    for (int s = 0; s < MAX_SECONDS; s++) {
        if (s < DURATION_SEC || accepted_per_second[s])
            printf(LOG "SECOND run_id=%s s=%d accepted=%ld\n", run_id, s, accepted_per_second[s]);
    }
    for (int e = 0; e < n_full_events; e++) {
        printf(LOG "BUFFULL run_id=%s start_us=%lld end_us=%lld\n", run_id,
               full_events[e].start_ns / 1000, full_events[e].end_ns / 1000);
    }
    for (int e = 0; e < n_sync_errors; e++) {
        printf(LOG "SYNCERR run_id=%s t_us=%lld code=%d phase=%s\n", run_id,
               sync_errors[e].t_ns / 1000, sync_errors[e].code,
               sync_errors[e].phase ? "drain" : "window");
    }
    printf(LOG "DRAIN run_id=%s syncs=%d drain_us=%lld errors=%ld unsent_after_drain=%ld\n",
           run_id, DRAIN_SYNCS, ns_since(t_d0, t_d1) / 1000, drain_errors, unsent_after_drain);
    printf(LOG "RECORDS run_id=%s buffull_events=%d buffull_dropped=%ld "
           "sync_errors=%d sync_errors_dropped=%ld\n",
           run_id, n_full_events, full_events_dropped, n_sync_errors, sync_errors_dropped);
    /* Kept for continuity with the thesis logs; now window-only (drain excluded). */
    printf(LOG "RESULT run_id=%s messages=%ld elapsed_sec=%.3f throughput_msgs_per_sec=%.1f\n",
           run_id, accepted, window_s, window_s > 0 ? accepted / window_s : 0.0);
    printf(LOG "CLIENT run_id=%s client_error_at_end=%d queue_len_at_end=%ld\n",
           run_id, client.error, (long)mqtt_mq_length(&client.mq));
    printf(LOG "done, idling\n");
    idle_forever();
    return 0;
}
