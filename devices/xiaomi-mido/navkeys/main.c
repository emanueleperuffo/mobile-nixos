/*
 * mido-navkeys: translate the bottom capacitive nav-button strip of the
 * FocalTech FT5x06 touchscreen into real KEY_BACK / KEY_HOME / KEY_MENU
 * events, injected through uinput.
 *
 * WHY THIS EXISTS
 * --------------
 * The touchscreen driver exposes the whole panel (nav strip included) as a
 * single touchscreen, so pressing the three bottom buttons just produces
 * ordinary touch coordinates - the OS never sees a "button". This daemon
 * watches the touchscreen input device and reinterprets touches that land
 * in the bottom strip as key events.
 *
 * HOW IT WORKS (matches the reference implementation)
 * ---------------------------------------------------
 * The strip's three buttons sit at FIXED positions in the touchscreen's
 * digitizer coordinate space (the digitizer is larger than the 1080x1920
 * display, so the strip sits below the visible area):
 *
 *     X=200 -> KEY_MENU,  X=500 -> KEY_HOME,  X=800 -> KEY_BACK,  Y=2040
 *
 * While the finger is down (BTN_TOUCH held), the daemon repeatedly checks
 * the CURRENT coordinates. If they land exactly on one of those positions,
 * the matching key is pressed and held; as soon as the finger lifts or
 * slides off the position, the key is released. Only one key is held at a
 * time. This gives press-and-hold semantics (e.g. hold HOME for recents).
 *
 * The device is auto-detected (the ft5x06 touchscreen), or can be given
 * explicitly as the first argument (/dev/input/eventN).
 */

#include <errno.h>
#include <fcntl.h>
#include <glob.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include <libevdev/libevdev.h>

/* Kernel device node used to create virtual input devices. */
#define UINPUT_DEV "/dev/uinput"

/* Nav-strip button positions, in the touchscreen's coordinate space
 * (values from the reference implementation). The digitizer's Y range is
 * larger than the display's: 2040 is below the 1920-line visible area. */
#define X_MENU 200
#define X_HOME 500
#define X_BACK 800
#define NAV_Y  2040

/* Linux input event codes for the keys we synthesize. (uinput.KEY_MENU,
 * KEY_HOME, KEY_BACK in evdev terms.) */
#define KEY_MENU_CODE 139
#define KEY_HOME_CODE 102
#define KEY_BACK_CODE 158

/*
 * Find the touchscreen's /dev/input/eventN node by walking /sys.
 *
 * /dev/input/eventN numbering is assigned at boot and can change between
 * reboots, so instead of hardcoding a node we scan all input devices and
 * match on the device NAME (read from sysfs), which is stable.
 */
static int find_touchscreen(char *out, size_t n) {
  glob_t g;
  if (glob("/sys/class/input/event*", 0, NULL, &g) != 0)
    return -1;

  for (size_t i = 0; i < g.gl_pathc; i++) {
    /* /sys/class/input/eventN/device/name holds the human-readable name. */
    char namepath[256];
    snprintf(namepath, sizeof(namepath), "%s/device/name", g.gl_pathv[i]);
    int fd = open(namepath, O_RDONLY);
    if (fd < 0)
      continue;
    char name[128] = {0};
    ssize_t r = read(fd, name, sizeof(name) - 1);
    close(fd);
    if (r <= 0)
      continue;

    /* The edt-ft5x06 driver exposes itself under a few name variants;
     * the Goodix controller is intentionally NOT matched (no nav strip). */
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

/*
 * Create the virtual input device that receives our synthetic key events.
 *
 * Steps:
 *  1. open /dev/uinput,
 *  2. declare which event types and key codes the device can emit
 *     (UI_SET_EVBIT/UI_SET_KEYBIT),
 *  3. describe it (UI_DEV_SETUP: bus type, vendor/product IDs, name),
 *  4. make it visible to the kernel (UI_DEV_CREATE).
 *
 * From then on, writing input_event structs to the fd is indistinguishable
 * from a real keypad to userspace (compositor, X/Wayland, ...).
 */
static int create_uinput(void) {
  int fd = open(UINPUT_DEV, O_WRONLY | O_NONBLOCK);
  if (fd < 0) {
    fprintf(stderr, "navkeys: cannot open %s: %s\n", UINPUT_DEV,
            strerror(errno));
    return -1;
  }

  /* We emit only EV_KEY events (plus the EV_SYN markers that frame them). */
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

  if (ioctl(fd, UI_DEV_SETUP, &setup) < 0 || ioctl(fd, UI_DEV_CREATE) < 0) {
    fprintf(stderr, "navkeys: uinput setup failed: %s\n", strerror(errno));
    close(fd);
    return -1;
  }
  return fd;
}

/*
 * Emit one key event with a trailing SYN_REPORT.
 *
 * value=1 presses the key, value=0 releases it. The EV_SYN/SYN_REPORT
 * frame tells the input stack "this batch of events is complete" - without
 * it the kernel would never deliver the state change to applications.
 */
static void emit_key(int ufd, int code, int value) {
  struct input_event ev;
  memset(&ev, 0, sizeof(ev));
  ev.type = EV_KEY;
  ev.code = code;
  ev.value = value;
  write(ufd, &ev, sizeof(ev));

  memset(&ev, 0, sizeof(ev));
  ev.type = EV_SYN;
  ev.code = SYN_REPORT;
  write(ufd, &ev, sizeof(ev));
}

/*
 * Read the CURRENT value of an axis from the device state.
 *
 * We prefer the multitouch axes (ABS_MT_POSITION_*); if the driver does not
 * expose them, fall back to the legacy single-touch axes (ABS_X/ABS_Y).
 * The ft5x06 reports both, with the same values, so the distinction is
 * cosmetic - but covering both keeps the daemon working across driver
 * variants.
 */
static int axis_value(struct libevdev *dev, int mt_code, int legacy_code,
                      int *out) {
  int v = 0;
  if (libevdev_has_event_code(dev, EV_ABS, mt_code) &&
      libevdev_fetch_event_value(dev, EV_ABS, mt_code, &v) == 0) {
    *out = v;
    return 1;
  }
  if (libevdev_has_event_code(dev, EV_ABS, legacy_code) &&
      libevdev_fetch_event_value(dev, EV_ABS, legacy_code, &v) == 0) {
    *out = v;
    return 1;
  }
  return 0;
}

/*
 * Map an exact X position to a key code; 0 if no button lives at that X.
 * The reference implementation only matches these exact positions, so a
 * touch between buttons is deliberately NOT a key press.
 */
static int mapping_for(int x) {
  switch (x) {
  case X_MENU:
    return KEY_MENU_CODE;
  case X_HOME:
    return KEY_HOME_CODE;
  case X_BACK:
    return KEY_BACK_CODE;
  default:
    return 0;
  }
}

int main(int argc, char **argv) {
  char devpath[64];

  /* Allow passing the device explicitly (like the reference script), but
   * keep the auto-detect so the systemd service needs no arguments. */
  if (argc > 1) {
    snprintf(devpath, sizeof(devpath), "%s", argv[1]);
  } else if (find_touchscreen(devpath, sizeof(devpath)) < 0) {
    fprintf(stderr, "navkeys: touchscreen not found\n");
    return 1;
  }

  int tfd = open(devpath, O_RDONLY);
  if (tfd < 0) {
    fprintf(stderr, "navkeys: cannot open %s: %s\n", devpath, strerror(errno));
    return 1;
  }

  /* libevdev wraps the raw input protocol: it decodes events, tracks the
   * device state (pressed keys, axis values), and transparently recovers
   * from SYN_DROPPED (kernel dropping events when the buffer overflows).
   * Without it we would have to replicate that state tracking by hand. */
  struct libevdev *dev = NULL;
  if (libevdev_new_from_fd(tfd, &dev) < 0) {
    fprintf(stderr, "navkeys: libevdev_new_from_fd failed: %s\n",
            strerror(errno));
    close(tfd);
    return 1;
  }

  int ufd = create_uinput();
  if (ufd < 0) {
    libevdev_free(dev);
    close(tfd);
    return 1;
  }

  fprintf(stderr, "navkeys: watching %s\n", devpath);

  /* The key currently held down on our virtual device, or 0 for none. */
  int active_key = 0;

  for (;;) {
    struct input_event ev;
    int rc = libevdev_next_event(dev, LIBEVDEV_READ_FLAG_NORMAL, &ev);
    if (rc == LIBEVDEV_READ_STATUS_SYNC)
      continue; /* state is re-read below, once the queue is back in sync */
    if (rc < 0)
      break;

    /*
     * Re-evaluate the CURRENT device state after every event, like the
     * reference implementation does (it checks active_keys()/absinfo on
     * each event from read_loop()).
     *
     * Why per-event instead of on BTN_TOUCH transitions only? Because the
     * finger can slide: it may start on a button and slide off (releasing
     * the key), or slide from one button to another (switching keys).
     * Re-reading the state each event catches those moves without us
     * tracking any history.
     */
    int wanted = 0;
    int touch = 0;
    /* BTN_TOUCH is the "a finger is actually on the panel" flag. Gating on
     * it also avoids stale MT-slot coordinates: after a lift the slot may
     * still hold the last position, and without the gate we would
     * re-trigger the key from leftover data. */
    if (libevdev_fetch_event_value(dev, EV_KEY, BTN_TOUCH, &touch) == 0 &&
        touch) {
      int x = 0, y = 0;
      /* A press counts only when the finger is exactly on a button
       * position: exact X match AND Y == NAV_Y. */
      if (axis_value(dev, ABS_MT_POSITION_X, ABS_X, &x) &&
          axis_value(dev, ABS_MT_POSITION_Y, ABS_Y, &y) && y == NAV_Y)
        wanted = mapping_for(x);
    }

    /*
     * Press-and-hold state machine: we only emit on TRANSITIONS.
     * - entering a button  : release the previous key (if any), press new
     * - staying on a button: emit nothing (avoids key-repeat spam)
     * - leaving / lifting  : release the key
     */
    if (wanted != active_key) {
      if (active_key)
        emit_key(ufd, active_key, 0);
      if (wanted)
        emit_key(ufd, wanted, 1);
      active_key = wanted;
    }
  }

  /* Clean up on exit: never leave a key stuck down. */
  if (active_key)
    emit_key(ufd, active_key, 0);

  close(ufd);
  libevdev_free(dev);
  close(tfd);
  return 0;
}
