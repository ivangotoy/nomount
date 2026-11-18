/*
 * Host test double for the nomount driver. userspace/src/nm.c is compiled with
 * -Dsyscall=nm_test_syscall -Dmain=nm_main and linked with this file; every
 * request nm sends is appended to $NM_FAKE_LOG as one line.
 */
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct fake_payload {
    unsigned long long magic;
    unsigned int cmd;
    unsigned int target_uid;
    int status;
    unsigned int arg1;
    unsigned int data_size;
    char buffer[4068];
} __attribute__((packed));

int nm_main(int argc, char **argv);

long nm_test_syscall(long nr, ...)
{
    va_list ap;
    unsigned long *ptr;
    struct fake_payload *p;
    const char *log = getenv("NM_FAKE_LOG");
    FILE *f;

    va_start(ap, nr);
    (void)va_arg(ap, const char *);
    (void)va_arg(ap, const char *);
    ptr = va_arg(ap, unsigned long *);
    va_end(ap);
    p = (struct fake_payload *)*ptr;

    if (log && (f = fopen(log, "a"))) {
        fprintf(f, "cmd=%u uid=%u arg1=%u size=%u\n", p->cmd, p->target_uid, p->arg1, p->data_size);
        fclose(f);
    }
    p->status = 0;
    switch (p->cmd) {
    case 1: /* NM_CMD_GET_VERSION */
        memcpy(p->buffer, "23", 2);
        p->data_size = 2;
        break;
    case 9: /* NM_CMD_GET_LIST */
    case 10: /* NM_CMD_GET_UIDS */
        p->data_size = 0;
        p->arg1 = ~0U;
        break;
    }
    errno = ECANCELED;
    return -1;
}

int main(int argc, char **argv)
{
    return nm_main(argc, argv);
}
