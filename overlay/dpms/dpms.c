#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <limits.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

/*
 * Discovering connector ids / names:
 *
 *   - With libdrm: `modetest -M msm -c | grep -E "^[0-9]+.*connected"` prints
 *     the connector id as the first number on each connected line.
 *
 *   - `ls /sys/class/drm/card0-*` shows the sysfs links: card0-DSI-1 -> the
 *     output name is "DSI-1" (after the dash); the numeric id comes from
 *     modetest above.
 *
 * This tool also does it for you: `dpms list` prints id, name, status and
 * current DPMS value for every connector.
 */

static void usage(const char *prog) {
  fprintf(stderr,
      "usage: %s list\n"
      "       %s <on|standby|suspend|off> <all|connector_id>\n"
      "\n"
      "  list                     print every connector (id, name, status and\n"
      "                           current DPMS value)\n"
      "  on|standby|suspend|off   set the DPMS state of the given connector\n"
      "  all|connector_id         target every DPMS-capable connector (`all`)\n"
      "                           or one specific connector (numeric id)\n"
      "\n"
      "DPMS = Display Power Management Signaling; the connector property that\n"
      "controls the display power state:\n"
      "  On=0 Standby=1 Suspend=2 Off=3\n"
      "`off` writes 3, `on` writes 0. Blanks/powers the panel while the system\n"
      "keeps running (no compositor required).\n",
      prog, prog);
}

/* Find the value of a named property on a connector.
 * Returns 0 and sets *value on success, -1 if the property is absent. */
static int get_prop(int fd, drmModeConnectorPtr c, const char *wanted,
                    uint64_t *value) {
  for (int p = 0; p < c->count_props; p++) {
    drmModePropertyPtr prop = drmModeGetProperty(fd, c->props[p]);
    if (!prop)
      continue;
    int match = strcmp(prop->name, wanted) == 0;
    drmModeFreeProperty(prop);
    if (match) {
      *value = c->prop_values[p];
      return 0;
    }
  }
  return -1;
}

/* Map drmModeConnector connector_type enum values to their names (matching
 * modetest output, e.g. DSI, eDP, HDMI-A, DP). */
static const char *connector_type_name(int t) {
  static const char *const names[] = {
    [DRM_MODE_CONNECTOR_Unknown]     = "Unknown",
    [DRM_MODE_CONNECTOR_VGA]         = "VGA",
    [DRM_MODE_CONNECTOR_DVII]        = "DVI-I",
    [DRM_MODE_CONNECTOR_DVID]        = "DVI-D",
    [DRM_MODE_CONNECTOR_DVIA]        = "DVI-A",
    [DRM_MODE_CONNECTOR_Composite]   = "Composite",
    [DRM_MODE_CONNECTOR_SVIDEO]      = "SVIDEO",
    [DRM_MODE_CONNECTOR_LVDS]        = "LVDS",
    [DRM_MODE_CONNECTOR_Component]   = "Component",
    [DRM_MODE_CONNECTOR_9PinDIN]     = "DIN",
    [DRM_MODE_CONNECTOR_DisplayPort] = "DP",
    [DRM_MODE_CONNECTOR_HDMIA]       = "HDMI-A",
    [DRM_MODE_CONNECTOR_HDMIB]       = "HDMI-B",
    [DRM_MODE_CONNECTOR_TV]          = "TV",
    [DRM_MODE_CONNECTOR_eDP]         = "eDP",
    [DRM_MODE_CONNECTOR_VIRTUAL]     = "Virtual",
    [DRM_MODE_CONNECTOR_DSI]         = "DSI",
    [DRM_MODE_CONNECTOR_DPI]         = "DPI",
    [DRM_MODE_CONNECTOR_WRITEBACK]   = "Writeback",
    [DRM_MODE_CONNECTOR_SPI]         = "SPI",
    [DRM_MODE_CONNECTOR_USB]         = "USB",
  };
  if (t < 0 || t >= (int)(sizeof names / sizeof names[0]) || !names[t])
    return "Unknown";
  return names[t];
}

/* Build a display name for the connector from its type + id (e.g. "DSI-1",
 * "eDP-1", "HDMI-A-1") — the same scheme modetest uses. */
static void connector_name(drmModeConnectorPtr c, char *buf, size_t len) {
  snprintf(buf, len, "%s-%u", connector_type_name(c->connector_type),
           c->connector_type_id);
}

/* Look for an EDID blob and pull out the monitor name (first 0xFC tag) to use
 * as a human-readable description. Returns 1 if a name was found. */
static int connector_edid_name(int fd, drmModeConnectorPtr c, char *buf,
                               size_t len) {
  for (int p = 0; p < c->count_props; p++) {
    drmModePropertyPtr prop = drmModeGetProperty(fd, c->props[p]);
    if (!prop)
      continue;
    int is_edid = strcmp(prop->name, "EDID") == 0;
    uint32_t blob_id = is_edid ? c->prop_values[p] : 0;
    drmModeFreeProperty(prop);
    if (!is_edid || blob_id == 0)
      continue;
    drmModePropertyBlobPtr blob = drmModeGetPropertyBlob(fd, blob_id);
    if (blob && blob->length >= 128) {
      const uint8_t *edid = blob->data;
      /* EDID v1: monitor descriptors start at 0x36; the 0xFC tag marks the
       * display/product name descriptor. */
      for (int d = 0x36; d + 18 <= 126; d += 18) {
        if (edid[d] == 0x00 && edid[d + 1] == 0x00 && edid[d + 2] == 0x00 &&
            edid[d + 3] == 0xFC && edid[d + 4] == 0x00 && edid[d + 5] == 0x00) {
          int n = 0;
          for (int i = d + 5; i < d + 18 && edid[i] && edid[i] != '\n'; i++)
            if (n < (int)len - 1)
              buf[n++] = edid[i];
          buf[n] = '\0';
          drmModeFreePropertyBlob(blob);
          return n > 0;
        }
      }
    }
    if (blob)
      drmModeFreePropertyBlob(blob);
    break;
  }
  return 0;
}

/* Map a subconnector property value (DRM_MODE_SUBCONNECTOR_*) to a name. */
static const char *subconnector_name(uint64_t v) {
  switch (v) {
    case DRM_MODE_SUBCONNECTOR_Unknown:    return "Unknown";
    case DRM_MODE_SUBCONNECTOR_VGA:        return "VGA";
    case DRM_MODE_SUBCONNECTOR_DVID:       return "DVI-D";
    case DRM_MODE_SUBCONNECTOR_DVIA:       return "DVI-A";
    case DRM_MODE_SUBCONNECTOR_Composite:  return "Composite";
    case DRM_MODE_SUBCONNECTOR_SVIDEO:     return "SVIDEO";
    case DRM_MODE_SUBCONNECTOR_Component:  return "Component";
    case DRM_MODE_SUBCONNECTOR_SCART:      return "SCART";
    case DRM_MODE_SUBCONNECTOR_DisplayPort:return "DisplayPort";
    case DRM_MODE_SUBCONNECTOR_HDMIA:      return "HDMI";
    case DRM_MODE_SUBCONNECTOR_Wireless:   return "Wireless";
    case DRM_MODE_SUBCONNECTOR_Native:     return "Native";
    default:                               return "?";
  }
}

/* Current mode resolution as "WxH@rate", or "none" if the connector has no
 * modes / is disconnected. The active mode is the first entry in c->modes. */
static void connector_mode(drmModeConnectorPtr c, char *buf, size_t len) {
  if (c->connection != DRM_MODE_CONNECTED || c->count_modes == 0) {
    snprintf(buf, len, "none");
    return;
  }
  const drmModeModeInfo *m = &c->modes[0];
  if (m->clock == 0) {
    snprintf(buf, len, "none");
    return;
  }
  snprintf(buf, len, "%ux%u@%uHz",
           m->hdisplay, m->vdisplay, (unsigned)(m->vrefresh + 0.5f));
}

/* Pick a DRM device node via libdrm's device enumeration. Returns the node
 * path in `buf` (malloc'd by libdrm, so this is a leak-free pointer into
 * the drmDevice's node array). Falls back to /dev/dri/card0. */
static const char *pick_card(drmDevicePtr *dev, int *card) {
  drmDevicePtr devices[64];
  int n = drmGetDevices2(0, devices, 64);
  if (n > 0) {
    for (int i = 0; i < n; i++) {
      /* Prefer a primary node (the one that does modesetting). */
      const char *node =
          devices[i]->available_nodes & (1 << DRM_NODE_PRIMARY)
              ? devices[i]->nodes[DRM_NODE_PRIMARY]
              : NULL;
      if (node) {
        *dev = devices[i];
        /* cardN <- parse trailing number from /dev/dri/cardN */
        int num = 0;
        const char *p = node;
        for (; *p; p++)
          if (*p >= '0' && *p <= '9')
            num = num * 10 + (*p - '0');
        *card = num;
        return node;
      }
    }
  }
  *card = 0;
  return "/dev/dri/card0";
}

static const char *dpms_state_name(int mode) {
  switch (mode) {
    case 1: return "on";
    case 2: return "standby";
    case 3: return "suspend";
    case 4: return "off";
    default: return "?";
  }
}

int main(int argc, char **argv) {
  drmDevicePtr dev = NULL;
  int card = 0;
  const char *card_path = pick_card(&dev, &card);
  int fd = open(card_path, O_RDWR);
  if (fd < 0) {
    perror("open");
    return 1;
  }

  if (argc < 2) {
    usage(argv[0]);
    return 2;
  }

  int mode; /* 0 = list, 1 = on, 2 = standby, 3 = suspend, 4 = off */
  if (!strcmp(argv[1], "list") || !strcmp(argv[1], "ls")) {
    mode = 0;
  } else if (!strcmp(argv[1], "on")) {
    mode = 1;
  } else if (!strcmp(argv[1], "standby")) {
    mode = 2;
  } else if (!strcmp(argv[1], "suspend")) {
    mode = 3;
  } else if (!strcmp(argv[1], "off")) {
    mode = 4;
  } else {
    usage(argv[0]);
    return 2;
  }

  drmModeRes *res = drmModeGetResources(fd);
  if (!res) {
    fprintf(stderr, "cannot get DRM resources\n");
    return 1;
  }

  /* `list` always shows everything; only on/standby/suspend/off take a target. */
  int target; /* -1 = all, >=0 = specific connector id */
  if (mode == 0) {
    target = -1;
  } else if (argc >= 3 && !strcmp(argv[2], "all")) {
    target = -1;
  } else if (argc >= 3) {
    target = atoi(argv[2]);
  } else {
    fprintf(stderr, "missing connector id; use a numeric id or `all`\n");
    usage(argv[0]);
    return 2;
  }
  int found = 0;

  for (int i = 0; i < res->count_connectors; i++) {
    drmModeConnectorPtr c = drmModeGetConnector(fd, res->connectors[i]);
    if (!c)
      continue;

    if (target != -1 && (int)c->connector_id != target) {
      drmModeFreeConnector(c);
      continue;
    }

    if (mode == 0) {
      uint64_t dpms = 0;
      const char *dpms_str = "?";
      if (get_prop(fd, c, "DPMS", &dpms) == 0) {
        static const char *enums[] = { "On", "Standby", "Suspend", "Off" };
        dpms_str = dpms < 4 ? enums[dpms] : "?";
      }
      char name[64];
      connector_name(c, name, sizeof name);
      char desc[64] = "";
      connector_edid_name(fd, c, desc, sizeof desc);
      char mode[64];
      connector_mode(c, mode, sizeof mode);
      uint64_t sub = 0;
      const char *sub_str = "-";
      if (get_prop(fd, c, "subconnector", &sub) == 0)
        sub_str = subconnector_name(sub);
      if (i == 0)
        printf("%-4s %-12s %-12s %-8s %-15s %-12s %-12s %s\n",
               "ID", "NAME", "STATUS", "DPMS", "MODE", "SIZE",
               "SUBCONNECTOR", "DESCRIPTION");
      char size[32];
      snprintf(size, sizeof size, "%ux%umm", c->mmWidth, c->mmHeight);
      printf("%-4u %-12s %-12s %-8s %-15s %-12s %-12s %s\n",
             c->connector_id, name,
             c->connection == DRM_MODE_CONNECTED ? "connected"
             : c->connection == DRM_MODE_DISCONNECTED ? "disconnected"
             : "unknown",
             dpms_str, mode, size, sub_str, desc);
      found = 1;
      drmModeFreeConnector(c);
      continue;
    }

    uint64_t dpms_prop = 0;
    if (get_prop(fd, c, "DPMS", &dpms_prop) != 0) {
      drmModeFreeConnector(c);
      continue;
    }

    int r = drmModeObjectSetProperty(fd, c->connector_id,
                                     DRM_MODE_OBJECT_CONNECTOR,
                                     dpms_prop, mode - 1);
    printf("DPMS %s on connector %u (%s)%s\n",
           dpms_state_name(mode), c->connector_id,
           r == 0 ? "ok" : "failed",
           r != 0 ? " - " : "");
    if (r != 0)
      fprintf(stderr, "  errno=%d (%s)\n", errno, strerror(errno));
    found = 1;

    drmModeFreeConnector(c);
  }

  if (!found) {
    fprintf(stderr, "no matching connector found\n");
    return 1;
  }

  drmModeFreeResources(res);
  if (dev)
    drmFreeDevice(&dev);
  return 0;
}