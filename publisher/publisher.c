/* MQTT throughput benchmark publisher (fixed-time window) */
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

static uint8_t sendbuf[65536];
static uint8_t recvbuf[4096];

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

static double ts_diff_sec(struct timespec a, struct timespec b) {
    return (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
}

int main(int argc, char *argv[]) {
    printf("UKL-MQTT-BENCH: starting, duration=%d sec\n", DURATION_SEC);

    int sock = connect_broker(BROKER_ADDR, BROKER_PORT);
    if (sock < 0) {
        printf("UKL-MQTT-BENCH: connect failed\n");
#ifndef BENCHMARK_EXIT
        for (;;) pause();
#endif
        return 1;
    }

    struct mqtt_client client;
    mqtt_init(&client, sock, sendbuf, sizeof(sendbuf),
              recvbuf, sizeof(recvbuf), NULL);
    mqtt_connect(&client, CLIENT_ID, NULL, NULL, 0, NULL, NULL,
                 MQTT_CONNECT_CLEAN_SESSION, 400);

    /* drive CONNACK */
    for (int t = 0; t < 100; t++) {
        mqtt_sync(&client);
        if (client.error != MQTT_OK && client.error != MQTT_ERROR_SEND_BUFFER_IS_FULL) {
            printf("UKL-MQTT-BENCH: mqtt connect error=%d\n", client.error);
#ifndef BENCHMARK_EXIT
            for (;;) pause();
#endif
            return 1;
        }
    }
    printf("UKL-MQTT-BENCH: broker connected, running for %d sec\n", DURATION_SEC);

    char payload[128];
    struct timespec t_start, t_now;
    int successful = 0;
    int i = 0;

    clock_gettime(CLOCK_MONOTONIC, &t_start);
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &t_now);
        if (ts_diff_sec(t_start, t_now) >= DURATION_SEC) break;

        int len = snprintf(payload, sizeof(payload),
                           "{\"seq\":%d,\"temp\":%d,\"humidity\":%d}",
                           i, 20 + (i % 10), 50 + (i % 30));

        enum MQTTErrors rc = mqtt_publish(&client, TOPIC, payload, len,
                                          MQTT_PUBLISH_QOS_0);
        if (rc == MQTT_OK) {
            successful++;
            i++;
        } else if (rc != MQTT_ERROR_SEND_BUFFER_IS_FULL) {
            printf("UKL-MQTT-BENCH: publish error code=%d at seq=%d\n", rc, i);
            break;
        }
        /* drive both send and receive */
        mqtt_sync(&client);
    }

    /* final drain */
    for (int j = 0; j < 200; j++) {
        mqtt_sync(&client);
    }

    clock_gettime(CLOCK_MONOTONIC, &t_now);
    double elapsed = ts_diff_sec(t_start, t_now);
    double throughput = (elapsed > 0) ? successful / elapsed : 0;

    printf("UKL-MQTT-BENCH: RESULT messages=%d elapsed_sec=%.3f throughput_msgs_per_sec=%.1f\n",
           successful, elapsed, throughput);
    printf("UKL-MQTT-BENCH: done, idling\n");
#ifndef BENCHMARK_EXIT
    for (;;) pause();
#endif
    return 0;
}
