#include <fcntl.h>

int TarvenOpenPipe(const char *path, int flags) {
  return open(path, flags);
}
