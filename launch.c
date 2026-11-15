// Small Ubuntu launcher; the game itself remains the Godot project beside it.
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(void) {
    char folder[PATH_MAX];
    ssize_t length = readlink("/proc/self/exe", folder, sizeof(folder) - 1);
    if (length < 0 || length >= (ssize_t)sizeof(folder) - 1) {
        perror("Cannot locate the game folder");
        return 1;
    }
    folder[length] = '\0';
    char *separator = strrchr(folder, '/');
    if (!separator) return 1;
    *separator = '\0';
    execlp("godot4", "godot4", "--path", folder, (char *)NULL);
    execl("/snap/bin/godot4", "godot4", "--path", folder, (char *)NULL);
    execlp("zenity", "zenity", "--error", "--text=Godot 4 could not be started. Install Godot 4, then open Play again.", (char *)NULL);
    perror("Cannot start Godot 4");
    return 1;
}
