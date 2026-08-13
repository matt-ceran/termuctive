#include <errno.h>
#include <stddef.h>
#include <unistd.h>

int main(void) {
    char buffer[4096];
    for (;;) {
        ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
        if (count == 0) {
            return 0;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return 1;
        }

        ssize_t written = 0;
        while (written < count) {
            ssize_t result = write(
                STDOUT_FILENO,
                buffer + written,
                (size_t)(count - written)
            );
            if (result < 0 && errno == EINTR) {
                continue;
            }
            if (result <= 0) {
                return 1;
            }
            written += result;
        }
    }
}
