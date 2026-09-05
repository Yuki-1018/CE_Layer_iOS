#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>
#include <netinet/in.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Slirp Slirp;

enum {
    SLIRP_POLL_IN = 1 << 0,
    SLIRP_POLL_OUT = 1 << 1,
    SLIRP_POLL_PRI = 1 << 2,
    SLIRP_POLL_ERR = 1 << 3,
    SLIRP_POLL_HUP = 1 << 4,
};

typedef ssize_t (*SlirpWriteCb)(const void *buffer, size_t length, void *opaque);
typedef void (*SlirpTimerCb)(void *opaque);
typedef int (*SlirpAddPollCb)(int fd, int events, void *opaque);
typedef int (*SlirpGetREventsCb)(int index, void *opaque);

typedef struct SlirpCb {
    SlirpWriteCb send_packet;
    void (*guest_error)(const char *message, void *opaque);
    int64_t (*clock_get_ns)(void *opaque);
    void *(*timer_new)(SlirpTimerCb callback, void *callback_opaque, void *opaque);
    void (*timer_free)(void *timer, void *opaque);
    void (*timer_mod)(void *timer, int64_t expiration_ns, void *opaque);
    void (*register_poll_fd)(int fd, void *opaque);
    void (*unregister_poll_fd)(int fd, void *opaque);
    void (*notify)(void *opaque);
} SlirpCb;

Slirp *slirp_init(int restricted, bool ipv4_enabled,
                  struct in_addr network, struct in_addr netmask, struct in_addr host,
                  bool ipv6_enabled, struct in6_addr ipv6_prefix, uint8_t ipv6_prefix_length,
                  struct in6_addr ipv6_host, const char *hostname,
                  const char *tftp_server_name, const char *tftp_path, const char *boot_file,
                  struct in_addr dhcp_start, struct in_addr name_server,
                  struct in6_addr ipv6_name_server, const char **dns_search,
                  const char *domain_name, const SlirpCb *callbacks, void *opaque);
void slirp_cleanup(Slirp *slirp);
void slirp_input(Slirp *slirp, const uint8_t *packet, int length);
void slirp_pollfds_fill(Slirp *slirp, uint32_t *timeout_ms,
                        SlirpAddPollCb add_poll, void *opaque);
void slirp_pollfds_poll(Slirp *slirp, int select_error,
                        SlirpGetREventsCb get_revents, void *opaque);
const char *slirp_version_string(void);

#ifdef __cplusplus
}
#endif
