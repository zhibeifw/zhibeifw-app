package com.zhibeifw.app

import com.zhibeifw.app.data.FileStatus
import com.zhibeifw.app.data.SyncSummary
import org.junit.Assert.*
import org.junit.Test

class CatalogStatusTest {
    @Test fun missingCatalogIsFailureButInvalidRemainsSilent() {
        assertTrue(SyncSummary(FileStatus.MISSING).failed)
        assertTrue(SyncSummary(FileStatus.FAILED).failed)
        for (status in listOf(FileStatus.INVALID, FileStatus.UPDATED, FileStatus.UNCHANGED)) {
            assertFalse(SyncSummary(status).failed)
        }
    }
}
