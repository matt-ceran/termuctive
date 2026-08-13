#ifndef TERMUCTIVE_AGENT_PROCESS_SHIM_H
#define TERMUCTIVE_AGENT_PROCESS_SHIM_H

#include <stdint.h>
#include <sys/types.h>

typedef struct TMCProcessInfo {
    int32_t processID;
    int32_t parentProcessID;
    int32_t processGroupID;
    int32_t foregroundProcessGroupID;
    uint64_t startSeconds;
    uint64_t startMicroseconds;
} TMCProcessInfo;

int32_t TMCReadProcessInfo(pid_t processID, TMCProcessInfo *processInfo);

int32_t TMCListProcessGroupPIDs(
    pid_t processGroupID,
    pid_t *processIDs,
    int32_t capacity
);

int32_t TMCReadProcessPath(
    pid_t processID,
    char *buffer,
    int32_t capacity
);

int32_t TMCReadProcessName(
    pid_t processID,
    char *buffer,
    int32_t capacity
);

int32_t TMCReadProcessArguments(
    pid_t processID,
    char *buffer,
    int32_t capacity
);

#endif
