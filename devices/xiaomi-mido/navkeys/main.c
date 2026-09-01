#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <libevdev/libevdev-uinput.h>
#include <libevdev/libevdev.h>
#include <linux/input.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TARGET_Y 2040
#define X_TOLERANCE 50

static bool verbose = false;

#define LOG_INFO(...) fprintf(stdout, "[INFO] " __VA_ARGS__)
#define LOG_DBG(...)                                                           \
  do {                                                                         \
    if (verbose)                                                               \
      fprintf(stdout, "[DEBUG] " __VA_ARGS__);                                 \
  } while (0)

struct nav_mapping {
  int center_x;
  int key_code;
  const char *name;
};

/* Mappings tailored for Phosh */
static const struct nav_mapping MAPPINGS[] = {
    {200, KEY_APPSELECT, "KEY_APPSELECT"}, /* Left:  App Switcher */
    {500, KEY_LEFTMETA, "KEY_LEFTMETA"},   /* Center: Phosh Home Screen */
    {800, KEY_BACK, "KEY_BACK"}            /* Right:  Back */
};
#define NUM_MAPPINGS (sizeof(MAPPINGS) / sizeof(MAPPINGS[0]))

static int get_key_code(int x, const char **key_name) {
  for (size_t i = 0; i < NUM_MAPPINGS; i++) {
    if (x >= MAPPINGS[i].center_x - X_TOLERANCE &&
        x <= MAPPINGS[i].center_x + X_TOLERANCE) {
      if (key_name)
        *key_name = MAPPINGS[i].name;
      return MAPPINGS[i].key_code;
    }
  }
  if (key_name)
    *key_name = NULL;
  return 0;
}

static char *find_touchscreen_path(void) {
  DIR *dir = opendir("/dev/input");
  if (!dir) {
    perror("Failed to open /dev/input");
    return NULL;
  }

  struct dirent *ent;
  char path[256];
  char *found_path = NULL;

  while ((ent = readdir(dir)) != NULL) {
    if (strncmp(ent->d_name, "event", 5) != 0)
      continue;

    snprintf(path, sizeof(path), "/dev/input/%s", ent->d_name);
    int fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0)
      continue;

    struct libevdev *dev = NULL;
    if (libevdev_new_from_fd(fd, &dev) < 0) {
      close(fd);
      continue;
    }

    /* Check for touchscreen characteristics: ABS position + BTN_TOUCH */
    bool has_abs = libevdev_has_event_type(dev, EV_ABS) &&
                   (libevdev_has_event_code(dev, EV_ABS, ABS_MT_POSITION_X) ||
                    libevdev_has_event_code(dev, EV_ABS, ABS_X));
    bool has_touch = libevdev_has_event_type(dev, EV_KEY) &&
                     libevdev_has_event_code(dev, EV_KEY, BTN_TOUCH);

    LOG_DBG("Checking %s: name=\"%s\", abs=%d, touch=%d\n", path,
            libevdev_get_name(dev), has_abs, has_touch);

    if (has_abs && has_touch) {
      found_path = strdup(path);
      LOG_INFO("Selected touchscreen device: %s (%s)\n", path,
               libevdev_get_name(dev));
      libevdev_free(dev);
      close(fd);
      break;
    }

    libevdev_free(dev);
    close(fd);
  }

  closedir(dir);
  return found_path;
}

static void send_key(struct libevdev_uinput *uidev, int code, int value,
                     const char *name) {
  LOG_INFO("Emitting %s (%d) -> %s\n", name ? name : "KEY", code,
           value ? "PRESS" : "RELEASE");
  libevdev_uinput_write_event(uidev, EV_KEY, code, value);
  libevdev_uinput_write_event(uidev, EV_SYN, SYN_REPORT, 0);
}

int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--verbose") == 0) {
      verbose = true;
    } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
      printf("Usage: %s [-v|--verbose]\n", argv[0]);
      return EXIT_SUCCESS;
    }
  }

  char *device_path = find_touchscreen_path();
  if (!device_path) {
    fprintf(stderr,
            "Error: Could not automatically detect a touchscreen device.\n");
    return EXIT_FAILURE;
  }

  int fd = open(device_path, O_RDONLY);
  if (fd < 0) {
    perror("Failed to open input device");
    free(device_path);
    return EXIT_FAILURE;
  }

  struct libevdev *dev = NULL;
  if (libevdev_new_from_fd(fd, &dev) < 0) {
    fprintf(stderr, "Failed to initialize libevdev for %s\n", device_path);
    free(device_path);
    close(fd);
    return EXIT_FAILURE;
  }

  struct libevdev *uidev_raw = libevdev_new();
  libevdev_set_name(uidev_raw, "pmos-navkeys");
  libevdev_enable_event_type(uidev_raw, EV_KEY);
  libevdev_enable_event_code(uidev_raw, EV_KEY, KEY_MENU, NULL);
  libevdev_enable_event_code(uidev_raw, EV_KEY, KEY_HOME, NULL);
  libevdev_enable_event_code(uidev_raw, EV_KEY, KEY_BACK, NULL);

  struct libevdev_uinput *uidev = NULL;
  if (libevdev_uinput_create_from_device(
          uidev_raw, LIBEVDEV_UINPUT_OPEN_MANAGED, &uidev) < 0) {
    fprintf(stderr, "Failed to create uinput device\n");
    libevdev_free(uidev_raw);
    libevdev_free(dev);
    free(device_path);
    close(fd);
    return EXIT_FAILURE;
  }
  libevdev_free(uidev_raw);

  LOG_INFO("Listening on %s... (press Ctrl+C to exit)\n", device_path);

  int cur_x = -1;
  int cur_y = -1;
  bool touch_down = false;
  int active_key = 0;
  const char *active_key_name = NULL;

  struct input_event ev;
  while (1) {
    int rc = libevdev_next_event(dev, LIBEVDEV_READ_FLAG_NORMAL, &ev);
    if (rc == -EAGAIN)
      continue;
    if (rc < 0) {
      LOG_INFO("Device disconnected or read error (rc=%d)\n", rc);
      break;
    }

    if (ev.type == EV_KEY && ev.code == BTN_TOUCH) {
      touch_down = (ev.value != 0);
      LOG_DBG("BTN_TOUCH: %d\n", touch_down);
    } else if (ev.type == EV_ABS) {
      if (ev.code == ABS_X || ev.code == ABS_MT_POSITION_X) {
        cur_x = ev.value;
      } else if (ev.code == ABS_Y || ev.code == ABS_MT_POSITION_Y) {
        cur_y = ev.value;
      }
    } else if (ev.type == EV_SYN && ev.code == SYN_REPORT) {
      LOG_DBG("SYN_REPORT frame: touch=%d, x=%d, y=%d\n", touch_down, cur_x,
              cur_y);

      const char *target_key_name = NULL;
      int target_key = 0;

      if (touch_down && cur_y == TARGET_Y) {
        target_key = get_key_code(cur_x, &target_key_name);
      }

      if (target_key != active_key) {
        if (active_key != 0) {
          send_key(uidev, active_key, 0, active_key_name);
        }
        if (target_key != 0) {
          send_key(uidev, target_key, 1, target_key_name);
        }
        active_key = target_key;
        active_key_name = target_key_name;
      }
    }
  }

  libevdev_uinput_destroy(uidev);
  libevdev_free(dev);
  free(device_path);
  close(fd);
  return EXIT_SUCCESS;
}
