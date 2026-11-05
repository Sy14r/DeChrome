// A headless local fixture for launcher lifecycle tests. Never loads real Chrome.
#include <arpa/inet.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;
static void stop_running(int signal_number) { (void)signal_number; running = 0; }

int main(int argc, char **argv) {
  const char *profile = getenv("DECHROME_PROFILE_PATH");
  for (int i = 1; i < argc; i++)
    if (!strncmp(argv[i], "--user-data-dir=", 16)) profile = argv[i] + 16;
  if (!profile || !*profile) return 2;
  signal(SIGTERM, stop_running);
  signal(SIGINT, stop_running);
  signal(SIGPIPE, SIG_IGN);
  mkdir(profile, 0700);

  int server = socket(AF_INET, SOCK_STREAM, 0);
  if (server < 0) return 3;
  struct sockaddr_in address = {0};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  if (bind(server, (struct sockaddr *)&address, sizeof(address)) || listen(server, 4)) return 4;
  socklen_t length = sizeof(address);
  if (getsockname(server, (struct sockaddr *)&address, &length)) return 5;
  unsigned port = ntohs(address.sin_port);

  char lock[PATH_MAX], port_path[PATH_MAX], host[256], lock_target[512];
  snprintf(lock, sizeof(lock), "%s/SingletonLock", profile);
  snprintf(port_path, sizeof(port_path), "%s/DevToolsActivePort", profile);
  gethostname(host, sizeof(host));
  host[sizeof(host) - 1] = 0;
  snprintf(lock_target, sizeof(lock_target), "%s-%d", host, getpid());
  unlink(lock);
  if (symlink(lock_target, lock)) return 6;
  FILE *file = fopen(port_path, "w");
  if (!file) return 7;
  fprintf(file, "%u\n/devtools/browser/fake-runtime-test\n", port);
  fclose(file);

  const char *log_path = getenv("DECHROME_LOG_PATH");
  if (log_path && (file = fopen(log_path, "a"))) {
    fprintf(file, "[DeChrome pid=%d] loaded executable=%s appMode=1\n", getpid(), argv[0]);
    fprintf(file, "[DeChrome pid=%d] window=1 configured full-size content={{0, 0}, {960, 720}} frame={{0, 0}, {960, 720}}\n", getpid());
    fflush(file);
    fclose(file);
  }
  const char *health_path = getenv("DECHROME_HEALTH_PATH");
  const char *launch_id = getenv("DECHROME_LAUNCH_ID");
  if (health_path && launch_id && (file = fopen(health_path, "w"))) {
    fprintf(file, "{\"launchID\":\"%s\",\"configured\":true,\"commandInterfaceReady\":true,\"role\":\"AXWindow\",\"subrole\":\"AXStandardWindow\",\"frame\":{\"width\":960,\"height\":720},\"content\":{\"width\":960,\"height\":720},\"renderer\":{\"width\":960,\"height\":720}}\n", launch_id);
    fclose(file);
  }

  while (running) {
    fd_set descriptors;
    FD_ZERO(&descriptors);
    FD_SET(server, &descriptors);
    struct timeval timeout = {.tv_sec = 0, .tv_usec = 100000};
    int ready = select(server + 1, &descriptors, NULL, NULL, &timeout);
    if (ready <= 0) continue;
    int client = accept(server, NULL, NULL);
    if (client < 0) continue;
    char request[4096] = {0}, body[4096], response[4608];
    ssize_t count = read(client, request, sizeof(request) - 1);
    if (count > 0) {
      if (strstr(request, "/json/version")) {
        snprintf(body, sizeof(body), "{\"Browser\":\"Chrome/157.0.0.0\",\"Protocol-Version\":\"1.3\",\"webSocketDebuggerUrl\":\"ws://127.0.0.1:%u/devtools/browser/fake-runtime-test\"}", port);
      } else {
        snprintf(body, sizeof(body), "[{\"id\":\"fake-runtime-test\",\"type\":\"page\",\"title\":\"Fake Chrome\",\"url\":\"about:blank\",\"webSocketDebuggerUrl\":\"ws://127.0.0.1:%u/devtools/page/fake-runtime-test\"}]", port);
      }
      int size = snprintf(response, sizeof(response), "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n%s", strlen(body), body);
      if (size > 0) (void)write(client, response, (size_t)size);
    }
    close(client);
  }
  close(server);
  unlink(lock);
  unlink(port_path);
  return 0;
}
