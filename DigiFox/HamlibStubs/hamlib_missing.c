// Missing hamlib symbols not included in the pre-built static library.
// Provides FIFO, timing, snapshot, and backend caps stubs.

#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <mach/mach_time.h>

#include "hamlib/rig.h"

// ============================================================
// FIFO implementation (matches hamlib fifo.h FIFO_RIG struct)
// ============================================================

#define HAMLIB_FIFO_SIZE 1024

typedef struct FIFO_RIG_s {
    char data[HAMLIB_FIFO_SIZE];
    int head;
    int tail;
    int flush;
    pthread_mutex_t mutex;
} FIFO_RIG;

void initFIFO(FIFO_RIG *fifo) {
    if (!fifo) return;
    memset(fifo, 0, sizeof(FIFO_RIG));
    pthread_mutex_init(&fifo->mutex, NULL);
}

void resetFIFO(FIFO_RIG *fifo) {
    if (!fifo) return;
    pthread_mutex_lock(&fifo->mutex);
    fifo->head = 0;
    fifo->tail = 0;
    fifo->flush = 0;
    pthread_mutex_unlock(&fifo->mutex);
}

int hl_push(FIFO_RIG *fifo, const char *msg) {
    if (!fifo || !msg) return -1;
    pthread_mutex_lock(&fifo->mutex);
    while (*msg) {
        int next = (fifo->head + 1) % HAMLIB_FIFO_SIZE;
        if (next == fifo->tail) { pthread_mutex_unlock(&fifo->mutex); return -1; }
        fifo->data[fifo->head] = *msg++;
        fifo->head = next;
    }
    pthread_mutex_unlock(&fifo->mutex);
    return 0;
}

int hl_pop(FIFO_RIG *fifo) {
    if (!fifo) return -1;
    pthread_mutex_lock(&fifo->mutex);
    if (fifo->head == fifo->tail) { pthread_mutex_unlock(&fifo->mutex); return -1; }
    int c = (unsigned char)fifo->data[fifo->tail];
    fifo->tail = (fifo->tail + 1) % HAMLIB_FIFO_SIZE;
    pthread_mutex_unlock(&fifo->mutex);
    return c;
}

int hl_peek(FIFO_RIG *fifo) {
    if (!fifo) return -1;
    pthread_mutex_lock(&fifo->mutex);
    if (fifo->head == fifo->tail) { pthread_mutex_unlock(&fifo->mutex); return -1; }
    int c = (unsigned char)fifo->data[fifo->tail];
    pthread_mutex_unlock(&fifo->mutex);
    return c;
}

// ============================================================
// monotonic_seconds (used by hl_usleep in sleep.c)
// ============================================================

double monotonic_seconds(void) {
    static mach_timebase_info_data_t info = {0, 0};
    if (info.denom == 0) mach_timebase_info(&info);
    uint64_t t = mach_absolute_time();
    return (double)(t * info.numer / info.denom) / 1e9;
}

// ============================================================
// Snapshot stubs (used by network.c)
// ============================================================

void snapshot_init(void) { }

int snapshot_serialize(size_t buffer_length, char *buffer, RIG *rig, void *p1, void *p2) {
    (void)rig; (void)p1; (void)p2;
    if (buffer && buffer_length > 0) buffer[0] = '\0';
    return 0;
}

// ============================================================
// Backend rig caps stubs - must use correct model IDs to avoid hash collisions.
// RIG_MAKE_MODEL(backend, num) = backend * 1000 + num

// Yaesu (1)
struct rig_caps ftx1_caps = { .rig_model = 1051, .model_name = "FTX1-stub", .mfg_name = "Yaesu", .version = "0.0" };

// FlexRadio (23)
struct rig_caps dttsp_rig_caps     = { .rig_model = 23003, .model_name = "DTTsp-stub", .mfg_name = "FlexRadio", .version = "0.0" };
struct rig_caps dttsp_udp_rig_caps = { .rig_model = 23004, .model_name = "DTTsp-UDP-stub", .mfg_name = "FlexRadio", .version = "0.0" };
struct rig_caps smartsdr_a_rig_caps = { .rig_model = 23005, .model_name = "SmartSDR-A-stub", .mfg_name = "FlexRadio", .version = "0.0" };
struct rig_caps smartsdr_b_rig_caps = { .rig_model = 23006, .model_name = "SmartSDR-B-stub", .mfg_name = "FlexRadio", .version = "0.0" };
struct rig_caps smartsdr_c_rig_caps = { .rig_model = 23007, .model_name = "SmartSDR-C-stub", .mfg_name = "FlexRadio", .version = "0.0" };
struct rig_caps smartsdr_d_rig_caps = { .rig_model = 23008, .model_name = "SmartSDR-D-stub", .mfg_name = "FlexRadio", .version = "0.0" };
struct rig_caps smartsdr_e_rig_caps = { .rig_model = 23009, .model_name = "SmartSDR-E-stub", .mfg_name = "FlexRadio", .version = "0.0" };
struct rig_caps smartsdr_f_rig_caps = { .rig_model = 23010, .model_name = "SmartSDR-F-stub", .mfg_name = "FlexRadio", .version = "0.0" };
struct rig_caps smartsdr_g_rig_caps = { .rig_model = 23011, .model_name = "SmartSDR-G-stub", .mfg_name = "FlexRadio", .version = "0.0" };
struct rig_caps smartsdr_h_rig_caps = { .rig_model = 23012, .model_name = "SmartSDR-H-stub", .mfg_name = "FlexRadio", .version = "0.0" };

// Kit (25)
struct rig_caps elektor304_caps = { .rig_model = 25001, .model_name = "Elektor304-stub", .mfg_name = "Kit", .version = "0.0" };
struct rig_caps drt1_caps        = { .rig_model = 25002, .model_name = "DRT1-stub", .mfg_name = "Kit", .version = "0.0" };
struct rig_caps dds60_caps       = { .rig_model = 25006, .model_name = "DDS60-stub", .mfg_name = "Kit", .version = "0.0" };
struct rig_caps miniVNA_caps     = { .rig_model = 25008, .model_name = "miniVNA-stub", .mfg_name = "Kit", .version = "0.0" };
struct rig_caps hiqsdr_caps      = { .rig_model = 25014, .model_name = "HiQSDR-stub", .mfg_name = "Kit", .version = "0.0" };
struct rig_caps sdr1k_rig_caps   = { .rig_model = 25099, .model_name = "SDR1000-stub", .mfg_name = "Kit", .version = "0.0" };
