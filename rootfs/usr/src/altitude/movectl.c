#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define MOVECTL_FIFO "/run/movectl.fifo"

static void die(const char *msg) {
  fprintf(stderr, "movectl: %s: %s\n", msg, strerror(errno));
  exit(1);
}

static int emit_event(int fd, unsigned short type, unsigned short code, int value) {
  struct input_event ev;
  memset(&ev, 0, sizeof(ev));
  ev.type = type;
  ev.code = code;
  ev.value = value;
  return write(fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev) ? 0 : -1;
}

static void syn(int fd) {
  if (emit_event(fd, EV_SYN, SYN_REPORT, 0) < 0)
    die("emit SYN_REPORT");
}

static int setup_uinput(void) {
  int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
  if (fd < 0)
    die("open /dev/uinput");

  if (ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0)
    die("UI_SET_EVBIT EV_KEY");
  if (ioctl(fd, UI_SET_KEYBIT, BTN_LEFT) < 0)
    die("UI_SET_KEYBIT BTN_LEFT");
  if (ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT) < 0)
    die("UI_SET_KEYBIT BTN_RIGHT");
  if (ioctl(fd, UI_SET_KEYBIT, BTN_MIDDLE) < 0)
    die("UI_SET_KEYBIT BTN_MIDDLE");
  if (ioctl(fd, UI_SET_EVBIT, EV_REL) < 0)
    die("UI_SET_EVBIT EV_REL");
  if (ioctl(fd, UI_SET_RELBIT, REL_X) < 0)
    die("UI_SET_RELBIT REL_X");
  if (ioctl(fd, UI_SET_RELBIT, REL_Y) < 0)
    die("UI_SET_RELBIT REL_Y");
  ioctl(fd, UI_SET_PROPBIT, INPUT_PROP_POINTER);

  struct uinput_setup usetup;
  memset(&usetup, 0, sizeof(usetup));
  usetup.id.bustype = BUS_USB;
  usetup.id.vendor = 0x1d6b;
  usetup.id.product = 0x0104;
  usetup.id.version = 1;
  snprintf(usetup.name, UINPUT_MAX_NAME_SIZE, "Altitude movectl pointer");

  if (ioctl(fd, UI_DEV_SETUP, &usetup) < 0)
    die("UI_DEV_SETUP");
  if (ioctl(fd, UI_DEV_CREATE) < 0)
    die("UI_DEV_CREATE");

  usleep(900000);
  return fd;
}

static void destroy_uinput(int fd) {
  ioctl(fd, UI_DEV_DESTROY);
  close(fd);
}

static void usage(void) {
  fprintf(stderr,
          "usage:\n"
          "  movectl move DX DY [STEPS]\n"
          "  movectl click [left]\n"
          "  movectl nudge\n"
          "  movectl daemon\n");
  exit(64);
}

static int to_int(const char *s) {
  char *end = NULL;
  long v = strtol(s, &end, 10);
  if (!s[0] || (end && *end) || v < -100000 || v > 100000)
    usage();
  return (int)v;
}

static void do_move(int fd, int dx, int dy, int steps) {
  if (steps < 1)
    steps = 1;
  for (int i = 0; i < steps; i++) {
    if (emit_event(fd, EV_REL, REL_X, dx / steps) < 0)
      die("emit REL_X");
    if (emit_event(fd, EV_REL, REL_Y, dy / steps) < 0)
      die("emit REL_Y");
    syn(fd);
    usleep(25000);
  }
}

static unsigned short button_code(const char *name) {
  if (!name || strcmp(name, "left") == 0)
    return BTN_LEFT;
  if (strcmp(name, "right") == 0)
    return BTN_RIGHT;
  if (strcmp(name, "middle") == 0)
    return BTN_MIDDLE;
  usage();
  return BTN_LEFT;
}

static void do_click(int fd, unsigned short button) {
  if (emit_event(fd, EV_KEY, button, 1) < 0)
    die("emit button down");
  syn(fd);
  usleep(60000);
  if (emit_event(fd, EV_KEY, button, 0) < 0)
    die("emit button up");
  syn(fd);
}

static void run_daemon(void) {
  int fd = setup_uinput();
  unlink(MOVECTL_FIFO);
  if (mkfifo(MOVECTL_FIFO, 0600) < 0)
    die("mkfifo " MOVECTL_FIFO);
  fprintf(stderr, "movectl: daemon ready on %s\n", MOVECTL_FIFO);

  for (;;) {
    FILE *fifo = fopen(MOVECTL_FIFO, "r");
    if (!fifo) {
      if (errno == EINTR)
        continue;
      die("open fifo");
    }
    char line[256];
    while (fgets(line, sizeof(line), fifo)) {
      char cmd[32] = {0};
      char arg[32] = {0};
      int dx = 0, dy = 0, steps = 1;
      int n = sscanf(line, "%31s %d %d %d", cmd, &dx, &dy, &steps);
      if (n >= 1 && strcmp(cmd, "move") == 0 && n >= 3) {
        do_move(fd, dx, dy, steps);
      } else if (n >= 1 && strcmp(cmd, "nudge") == 0) {
        do_move(fd, 280, 0, 8);
      } else if (n >= 1 && strcmp(cmd, "click") == 0) {
        sscanf(line, "%31s %31s", cmd, arg);
        do_click(fd, button_code(arg[0] ? arg : "left"));
      } else if (n >= 1 && strcmp(cmd, "quit") == 0) {
        fclose(fifo);
        unlink(MOVECTL_FIFO);
        destroy_uinput(fd);
        return;
      }
    }
    fclose(fifo);
  }
}

int main(int argc, char **argv) {
  if (argc < 2)
    usage();

  if (strcmp(argv[1], "daemon") == 0) {
    run_daemon();
    return 0;
  }

  int fd = setup_uinput();

  if (strcmp(argv[1], "move") == 0) {
    if (argc < 4 || argc > 5)
      usage();
    int dx = to_int(argv[2]);
    int dy = to_int(argv[3]);
    int steps = argc == 5 ? to_int(argv[4]) : 1;
    do_move(fd, dx, dy, steps);
  } else if (strcmp(argv[1], "click") == 0) {
    if (argc > 3)
      usage();
    do_click(fd, button_code(argc == 3 ? argv[2] : "left"));
  } else if (strcmp(argv[1], "nudge") == 0) {
    do_move(fd, 280, 0, 8);
  } else {
    usage();
  }

  usleep(900000);
  destroy_uinput(fd);
  return 0;
}
