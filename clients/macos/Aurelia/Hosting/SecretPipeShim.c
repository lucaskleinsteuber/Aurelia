#include <fcntl.h>

int AureliaOpenPipe(const char *path, int flags) {
  return open(path, flags);
}
