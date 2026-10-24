/* Trusted syscall probes for L14. Never print file contents or environment. */
#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void sleep_ms(long millis) {
  struct timespec remaining = {millis / 1000, (millis % 1000) * 1000000};
  while (nanosleep(&remaining, &remaining) < 0 && errno == EINTR) {}
}

static int denied(int error) { return error == EACCES || error == EPERM; }

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0);
  if (argc < 2) return 64;

  if (!strcmp(argv[1], "rw") && argc == 3) {
    const char *payload = "controlled fixture\n";
    char bytes[64] = {0};
    int fd = open(argv[2], O_CREAT | O_TRUNC | O_WRONLY, 0600);
    if (fd < 0) return 10;
    ssize_t written = write(fd, payload, strlen(payload));
    close(fd);
    fd = open(argv[2], O_RDONLY);
    if (fd < 0) return 11;
    ssize_t got = read(fd, bytes, sizeof(bytes));
    close(fd);
    int ok = written == (ssize_t)strlen(payload) && got == written &&
             memcmp(bytes, payload, (size_t)written) == 0;
    printf("{\"probe\":\"rw\",\"ok\":%s}\n", ok ? "true" : "false");
    return ok ? 0 : 12;
  }

  if ((!strcmp(argv[1], "read-denied") || !strcmp(argv[1], "write-denied")) && argc == 3) {
    int writing = !strcmp(argv[1], "write-denied");
    int fd = open(argv[2], writing ? O_WRONLY | O_TRUNC : O_RDONLY);
    int error = errno;
    if (fd >= 0) close(fd);
    int ok = fd < 0 && denied(error);
    printf("{\"probe\":\"%s\",\"denied\":%s,\"errno\":%d}\n",
           argv[1], ok ? "true" : "false", fd < 0 ? error : 0);
    return ok ? 0 : 13;
  }

  if (!strcmp(argv[1], "link-denied") && argc == 4) {
    int result = link(argv[2], argv[3]);
    int error = errno;
    if (result == 0) unlink(argv[3]);
    int blocked = result < 0 && denied(error);
    printf("{\"probe\":\"link-denied\",\"denied\":%s,\"errno\":%d}\n",
           blocked ? "true" : "false", result < 0 ? error : 0);
    return blocked ? 0 : 24;
  }

  if ((!strcmp(argv[1], "connect") || !strcmp(argv[1], "connect-denied")) && argc == 3) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(0x7f000001U);
    address.sin_port = htons((uint16_t)strtol(argv[2], NULL, 10));
    int result = fd < 0 ? -1 : connect(fd, (struct sockaddr *)&address, sizeof(address));
    int error = errno;
    if (fd >= 0) close(fd);
    int connected = result == 0;
    int blocked = result < 0 && denied(error);
    printf("{\"probe\":\"%s\",\"connected\":%s,\"denied\":%s,\"errno\":%d}\n",
           argv[1], connected ? "true" : "false", blocked ? "true" : "false",
           connected ? 0 : error);
    return (!strcmp(argv[1], "connect") ? connected : blocked) ? 0 : 14;
  }

  if (!strcmp(argv[1], "fork-denied") && argc == 2) {
    pid_t child = fork();
    int error = errno;
    if (child == 0) _exit(0);
    if (child > 0) waitpid(child, NULL, 0);
    int blocked = child < 0 && (denied(error) || error == EAGAIN);
    printf("{\"probe\":\"fork-denied\",\"denied\":%s,\"errno\":%d}\n",
           blocked ? "true" : "false", child < 0 ? error : 0);
    return blocked ? 0 : 15;
  }

  if (!strcmp(argv[1], "spawn-denied") && argc == 2) {
    pid_t child = -1;
    char *child_args[] = {argv[0], "sleep", "0", NULL};
    char *child_environment[] = {NULL};
    int error = posix_spawn(&child, argv[0], NULL, NULL, child_args, child_environment);
    if (error == 0) waitpid(child, NULL, 0);
    int blocked = denied(error) || error == EAGAIN;
    printf("{\"probe\":\"spawn-denied\",\"denied\":%s,\"errno\":%d}\n",
           blocked ? "true" : "false", error);
    return blocked ? 0 : 22;
  }

  if (!strcmp(argv[1], "setsid-denied") && argc == 2) {
    pid_t result = setsid();
    int error = errno;
    int blocked = result < 0 && denied(error);
    printf("{\"probe\":\"setsid-denied\",\"denied\":%s,\"errno\":%d}\n",
           blocked ? "true" : "false", result < 0 ? error : 0);
    return blocked ? 0 : 23;
  }

  if (!strcmp(argv[1], "file-size") && argc == 3) {
    signal(SIGXFSZ, SIG_IGN);
    char bytes[1024];
    memset(bytes, 'f', sizeof(bytes));
    int fd = open(argv[2], O_CREAT | O_TRUNC | O_WRONLY, 0600);
    if (fd < 0) return 16;
    long total = 0;
    ssize_t written;
    while ((written = write(fd, bytes, sizeof(bytes))) > 0) total += written;
    int error = errno;
    close(fd);
    printf("{\"probe\":\"file-size\",\"limited\":%s,\"bytes\":%ld,\"errno\":%d}\n",
           error == EFBIG ? "true" : "false", total, error);
    return error == EFBIG ? 0 : 17;
  }

  if (!strcmp(argv[1], "cpu") && argc == 2) {
    volatile uint64_t work = 1;
    printf("{\"probe\":\"cpu\",\"pid\":%d}\n", getpid());
    for (;;) work = work * UINT64_C(6364136223846793005) + 1;
  }

  if (!strcmp(argv[1], "output") && argc == 2) {
    char bytes[1024];
    memset(bytes, 'o', sizeof(bytes));
    for (;;) if (write(STDOUT_FILENO, bytes, sizeof(bytes)) < 0) return 18;
  }

  if (!strcmp(argv[1], "sleep") && (argc == 3 || argc == 5)) {
    if (argc == 5) {
      int fd = open(argv[3], O_CREAT | O_EXCL | O_WRONLY, 0600);
      if (fd < 0) return 20;
      char identity[256];
      int size = snprintf(identity, sizeof(identity), "{\"pid\":%d,\"nonce\":\"%s\"}\n", getpid(), argv[4]);
      if (size <= 0 || size >= (int)sizeof(identity) || write(fd, identity, (size_t)size) != size) return 21;
      close(fd);
    }
    printf("{\"probe\":\"sleep\",\"pid\":%d}\n", getpid());
    sleep_ms(strtol(argv[2], NULL, 10));
    return 0;
  }

  if (!strcmp(argv[1], "fds") && argc == 2) {
    int count = 0;
    int descriptors[128];
    while (count < 128) {
      int fd = open("/dev/null", O_RDONLY);
      if (fd < 0) break;
      descriptors[count++] = fd;
    }
    int error = errno;
    for (int i = 0; i < count; i++) close(descriptors[i]);
    printf("{\"probe\":\"fds\",\"limited\":%s,\"opened\":%d,\"errno\":%d}\n",
           error == EMFILE ? "true" : "false", count, error);
    return error == EMFILE ? 0 : 19;
  }

  return 64;
}
