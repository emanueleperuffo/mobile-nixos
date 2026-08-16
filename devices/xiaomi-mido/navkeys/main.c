/*
 * mido-navkeys: translate the bottom capacitive nav-button strip of the
 * FocalTech FT5x06 touchscreen into real KEY_BACK / KEY_HOME / KEY_MENU
 * events, injected through uinput.
 *
 * The touchscreen driver exposes the whole panel (nav strip included) as a
 * single touchscreen, so pressing the three bottom buttons just produces
 * ordinary touch coordinates. This daemon watches the touchscreen input
 * device, and when a touch-down lands in the bottom strip it emits the
 * corresponding key instead.
 *
 * Detection: a touch-down is treated as a nav-button press when its reported
 * Y is at/above the strip threshold, OR when no Y coordinate was reported at
 * all (the controller often reports nav touches with X only). It is then
 * classified into a button by its X zone.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <glob.h>
#include <sys/ioctl.h>
#include <linux/input.h>
#include <linux/uinput.h>

#define UINPUT_DEV "/dev/uinput"

#define STRIP_Y 2030       /* touch Y >= this is inside the button strip */
#define X_MENU_HI 350      /* X <  this           -> KEY_MENU  */
#define X_HOME_HI 650      /* X in [X_MENU_HI, ..) -> KEY_HOME  */
                           /* X >= this           -> KEY_BACK   */

#define KEY_MENU_CODE 139
#define KEY_HOME_CODE 102
#define KEY_BACK_CODE 158

/* Find the ft5x06 touchscreen /dev/input/eventN by matching its sysfs name. */
static int find_touchscreen(char *out, size_t n)
{
    glob_t g;
    if (glob("/sys/class/input/event*", 0, NULL, &g) != 0)
        return -1;

    for (size_t i = 0; i < g.gl_pathc; i++) {
        char namepath[256];
        snprintf(namepath, sizeof(namepath), "%s/device/name", g.gl_pathc ? g.gl_pathv[i] : "");
        int fd = open(namepath, O_RDONLY);
        if (fd < 0)
            continue;
        char name[128] = {0};
        ssize_t r = read(fd, name, sizeof(name) - 1);
        close(fd);
        if (r <= 0)
            continue;

        if (strstr(name, "ft5x06") || strstr(name, "fts") || strstr(name, "edt")) {
            /* /sys/class/input/eventN -> /dev/input/eventN */
            const char *leaf = strrchr(g.gl_pathv[i], '/');
            if (!leaf)
                continue;
            snprintf(out, n, "/dev/input%s", leaf);
            globfree(&g);
            return 0;
        }
    }
    globfree(&g);
    return -1;
}

static int create_uinput(void)
{
    int fd = open(UINPUT_DEV, O_WRONLY | O_NONBLOCK);
    if (fd < 0) {
        fprintf(stderr, "navkeys: cannot open %s: %s\n", UINPUT_DEV, strerror(errno));
        return -1;
    }

    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_EVBIT, EV_SYN);
    ioctl(fd, UI_SET_KEYBIT, KEY_MENU_CODE);
    ioctl(fd, UI_SET_KEYBIT, KEY_HOME_CODE);
    ioctl(fd, UI_SET_KEYBIT, KEY_BACK_CODE);

    struct uinput_setup setup;
    memset(&setup, 0, sizeof(setup));
    setup.id.bustype = BUS_VIRTUAL;
    setup.id.vendor = 0x1234;
    setup.id.product = 0x5678;
    strcpy(setup.name, "mido-navkeys");

    if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 ||
        ioctl(fd, UI_DEV_CREATE) < 0) {
        fprintf(stderr, "navkeys: uinput setup failed: %s\n", strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

static void emit_key(int ufd, int code)
{
    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = EV_KEY;
    ev.code = code;
    ev.value = 1;
    write(ufd, &ev, sizeof(ev));
    ev.value = 0;
    write(ufd, &ev, sizeof(ev));

    memset(&ev, 0, sizeof(ev));
    ev.type = EV_SYN;
    ev.code = SYN_REPORT;
    write(ufd, &ev, sizeof(ev));
}

static int classify(int x)
{
    if (x < X_MENU_HI)
        return KEY_MENU_CODE;
    if (x < X_HOME_HI)
        return KEY_HOME_CODE;
    return KEY_BACK_CODE;
}

int main(void)
{
    char devpath[64];
    if (find_touchscreen(devpath, sizeof(devpath)) < 0) {
        fprintf(stderr, "navkeys: touchscreen not found\n");
        return 1;
    }

    int tfd = open(devpath, O_RDONLY);
    if (tfd < 0) {
        fprintf(stderr, "navkeys: cannot open %s: %s\n", devpath, strerror(errno));
        return 1;
    }

    int ufd = create_uinput();
    if (ufd < 0) {
        close(tfd);
        return 1;
    }

    fprintf(stderr, "navkeys: watching %s\n", devpath);

    struct input_event ev;
    int cx = 0, cy = 0, have_y = 0;

    for (;;) {
        ssize_t n = read(tfd, &ev, sizeof(ev));
        if (n < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "navkeys: read error: %s\n", strerror(errno));
            break;
        }
        if ((size_t)n != sizeof(ev))
            continue;

        switch (ev.type) {
        case EV_ABS:
            switch (ev.code) {
            case ABS_MT_POSITION_X: case ABS_X: cx = ev.value; break;
            case ABS_MT_POSITION_Y: case ABS_Y: cy = ev.value; have_y = 1; break;
            }
            break;
        case EV_KEY:
            if (ev.code == BTN_TOUCH) {
                if (ev.value == 1) {
                    /* A nav button: either Y reports the bottom strip, or no Y
                     * was sent at all (the controller often reports nav touches
                     * with X only). Guard on X so spurious no-coordinate touches
                     * (e.g. cx=0) can't false-trigger. */
                    int is_button =
                        (have_y && cy >= STRIP_Y) ||
                        (!have_y && cx >= 100);
                    if (is_button) {
                        int k = classify(cx);
                        fprintf(stderr, "navkeys: emitting key %d\n", k);
                        emit_key(ufd, k);
                    }
                }
            }
            break;
        case EV_SYN:
            cx = 0; cy = 0; have_y = 0;
            break;
        }
    }

    close(ufd);
    close(tfd);
    return 0;
}