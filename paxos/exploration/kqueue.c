// Code directly lifted from:
// https://habr.com/en/articles/600123/#what-is-kernel-queue

/* Kernel Queue The Complete Guide: kqueue-accept.c: Accept socket connection
Usage:
        $ ./kqueue-accept
        $ curl 127.0.0.1:64000/
*/
#include <assert.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdio.h>
#include <sys/event.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

int kq;

// the structure associated with a socket descriptor
struct context {
  int sk;
  void (*rhandler)(struct context *obj);
};

void accept_handler(struct context *obj) {
  printf("Received socket READ event via kqueue\n");

  int csock = accept(obj->sk, NULL, 0);
  assert(csock != -1);
  close(csock);
}

void set_nonblock(int sk) {
  int flags = fcntl(sk, F_GETFL, 0);
  assert(flags != -1);
  assert(0 == fcntl(sk, F_SETFL, flags | O_NONBLOCK));
}

int main() {
  // create kqueue object
  kq = kqueue();
  assert(kq != -1);

  struct context obj = {};
  obj.rhandler = accept_handler;

  // create and prepare a socket
  obj.sk = socket(AF_INET, SOCK_STREAM, 0);
  assert(obj.sk != -1);
  set_nonblock(obj.sk);

  int val = 1;
  setsockopt(obj.sk, SOL_SOCKET, SO_REUSEADDR, &val, 4);

  struct sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(64000);
  assert(0 == bind(obj.sk, (struct sockaddr *)&addr, sizeof(addr)));
  assert(0 == listen(obj.sk, 0));

  // attach socket to kqueue
  struct kevent events[2];
  EV_SET(&events[0], obj.sk, EVFILT_READ, EV_ADD | EV_CLEAR, 0, 0, &obj);
  EV_SET(&events[1], obj.sk, EVFILT_WRITE, EV_ADD | EV_CLEAR, 0, 0, &obj);
  assert(0 == kevent(kq, events, 2, NULL, 0, NULL));

  // wait for incoming events from kqueue
  struct timespec *timeout = NULL; // wait indefinitely
  int n = kevent(kq, NULL, 0, events, 1, timeout);
  assert(n > 0);

  // process the received event
  struct context *o = events[0].udata;
  if (events[0].filter == EVFILT_READ)
    o->rhandler(o); // handle read event

  close(obj.sk);
  close(kq);

  return 0;
}
