#include "AgentProcessShim.h"

#include <libproc.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/sysctl.h>

#ifndef KERN_PROCARGS2
#define KERN_PROCARGS2 49
#endif

int32_t TMCReadProcessInfo(pid_t processID, TMCProcessInfo *processInfo) {
    if (processInfo == NULL || processID <= 0) {
        return 0;
    }

    memset(processInfo, 0, sizeof(*processInfo));
    struct proc_bsdinfo bsdInfo;
    memset(&bsdInfo, 0, sizeof(bsdInfo));
    int bsdBytes = proc_pidinfo(
        processID,
        PROC_PIDTBSDINFO,
        0,
        &bsdInfo,
        (int)sizeof(bsdInfo)
    );
    if (bsdBytes != (int)sizeof(bsdInfo)) {
        return 0;
    }

    processInfo->processID = (int32_t)bsdInfo.pbi_pid;
    processInfo->parentProcessID = (int32_t)bsdInfo.pbi_ppid;
    processInfo->processGroupID = (int32_t)bsdInfo.pbi_pgid;
    processInfo->foregroundProcessGroupID = (int32_t)bsdInfo.e_tpgid;
    processInfo->startSeconds = bsdInfo.pbi_start_tvsec;
    processInfo->startMicroseconds = bsdInfo.pbi_start_tvusec;

    struct proc_taskinfo taskInfo;
    memset(&taskInfo, 0, sizeof(taskInfo));
    int taskBytes = proc_pidinfo(
        processID,
        PROC_PIDTASKINFO,
        0,
        &taskInfo,
        (int)sizeof(taskInfo)
    );
    if (taskBytes == (int)sizeof(taskInfo)) {
        processInfo->cpuTimeNanoseconds =
            taskInfo.pti_total_user + taskInfo.pti_total_system;
    }

    return 1;
}

int32_t TMCListProcessGroupPIDs(
    pid_t processGroupID,
    pid_t *processIDs,
    int32_t capacity
) {
    if (processGroupID <= 0 || capacity < 0) {
        return -1;
    }
    if (capacity == 0) {
        return (int32_t)proc_listpgrppids(processGroupID, NULL, 0);
    }
    if (processIDs == NULL) {
        return -1;
    }
    return (int32_t)proc_listpgrppids(
        processGroupID,
        processIDs,
        capacity * (int32_t)sizeof(pid_t)
    );
}

int32_t TMCReadProcessPath(
    pid_t processID,
    char *buffer,
    int32_t capacity
) {
    if (processID <= 0 || buffer == NULL || capacity <= 1) {
        return 0;
    }
    buffer[0] = '\0';
    int length = proc_pidpath(processID, buffer, (uint32_t)capacity);
    if (length <= 0 || length >= capacity) {
        buffer[0] = '\0';
        return 0;
    }
    buffer[length] = '\0';
    return (int32_t)length;
}

int32_t TMCReadProcessName(
    pid_t processID,
    char *buffer,
    int32_t capacity
) {
    if (processID <= 0 || buffer == NULL || capacity <= 1) {
        return 0;
    }
    buffer[0] = '\0';
    int length = proc_name(processID, buffer, (uint32_t)capacity);
    if (length <= 0 || length >= capacity) {
        buffer[0] = '\0';
        return 0;
    }
    buffer[length] = '\0';
    return (int32_t)length;
}

static char *TMCSkipString(char *cursor, const char *end) {
    while (cursor < end && *cursor != '\0') {
        cursor += 1;
    }
    return cursor < end ? cursor + 1 : NULL;
}

int32_t TMCReadProcessArguments(
    pid_t processID,
    char *buffer,
    int32_t capacity
) {
    if (processID <= 0 || buffer == NULL || capacity <= 1) {
        return 0;
    }
    buffer[0] = '\0';

    int managementInformationBase[3] = {CTL_KERN, KERN_PROCARGS2, processID};
    size_t rawSize = 0;
    if (sysctl(managementInformationBase, 3, NULL, &rawSize, NULL, 0) != 0) {
        return 0;
    }
    if (rawSize < sizeof(int) || rawSize > 1024 * 1024) {
        return 0;
    }

    char *raw = malloc(rawSize);
    if (raw == NULL) {
        return 0;
    }
    size_t receivedSize = rawSize;
    if (sysctl(managementInformationBase, 3, raw, &receivedSize, NULL, 0) != 0
        || receivedSize < sizeof(int)) {
        free(raw);
        return 0;
    }

    int argumentCount = 0;
    memcpy(&argumentCount, raw, sizeof(argumentCount));
    if (argumentCount <= 0 || argumentCount > 4096) {
        free(raw);
        return 0;
    }

    char *cursor = raw + sizeof(argumentCount);
    const char *end = raw + receivedSize;
    cursor = TMCSkipString(cursor, end);
    if (cursor == NULL) {
        free(raw);
        return 0;
    }
    while (cursor < end && *cursor == '\0') {
        cursor += 1;
    }

    int32_t written = 0;
    for (int index = 0; index < argumentCount && cursor < end; index += 1) {
        char *argumentEnd = memchr(cursor, '\0', (size_t)(end - cursor));
        if (argumentEnd == NULL) {
            break;
        }
        size_t argumentLength = (size_t)(argumentEnd - cursor);
        if (argumentLength + 1 > (size_t)(capacity - written)) {
            break;
        }
        memcpy(buffer + written, cursor, argumentLength);
        written += (int32_t)argumentLength;
        buffer[written] = '\0';
        written += 1;
        cursor = argumentEnd + 1;
    }

    free(raw);
    return written;
}
