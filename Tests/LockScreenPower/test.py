#!/usr/bin/env python3
"""Source-level LockScreen safety guards; not an iOS encoder/runtime test."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
LOCK = ROOT / "Sources" / "EeveeSpotify" / "LockScreen"


def section(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class LockScreenPowerChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.controller = (LOCK / "LockScreenLyricsController.swift").read_text(encoding="utf-8")
        cls.renderer = (LOCK / "LyricClipRenderer.swift").read_text(encoding="utf-8")

    def test_dispatch_encoding_has_cooperative_cancellation(self):
        write = section(self.renderer, "static func write(", "private static func pairFrames(")
        self.assertIn("withTaskCancellationHandler", write)
        self.assertIn("onCancel:", write)
        self.assertIn("cancellation.cancel()", write)
        self.assertIn("for frame in pair {\n                                try cancellation.check()", write)
        self.assertIn("for frame in karaoke {\n                                try cancellation.check()", write)
        encode = section(self.renderer, "private static func writeFrames(", "private static func draw(_ image:")
        self.assertIn("while !input.isReadyForMoreMediaData {\n                    try cancellation.check()", encode)
        self.assertIn("done.wait(timeout:", encode)
        self.assertIn("writer.cancelWriting()", encode)
        self.assertIn("defer { try? FileManager.default.removeItem(at: partial) }", encode)
        publish = encode.split("try cancellation.publish {", 1)
        self.assertEqual(len(publish), 2)
        self.assertNotIn("removeItem(at: destination)", publish[0])
        self.assertIn("moveItem(at: partial, to: destination)", publish[1])
        guard = section(self.renderer, "func publish(", "/// 对唱叠句的合并帧表")
        self.assertLess(guard.index("lock.lock()"), guard.index("if cancelled"))
        self.assertLess(guard.index("if cancelled"), guard.index("try work()"))

    def test_tasks_are_cancelled_and_cleanup_checks_identity(self):
        self.assertNotIn("clipTasks.removeAll()", self.controller)
        cancel = section(self.controller, "private func cancelClipTasksLocked(", "private func isInstallCurrent(")
        self.assertIn("entry.task.cancel()", cancel)
        self.assertIn("clipTasks[path] = nil", cancel)
        clip = section(self.controller, "private func clipURL(", "// MARK: - 状态")
        self.assertIn("artworkRevision == revision", clip)
        self.assertIn("lineIndex == installedLineIndex", clip)
        self.assertIn("clipTasks[file.path]?.token == token", clip)
        self.assertEqual(clip.count("return stillCurrent ? result : nil"), 2)
        self.assertLess(clip.index("lock.lock()"), clip.index("fileExists(atPath:"))

    def test_idle_polling_keeps_lyric_cadence_and_metadata_wakes(self):
        refresh = section(self.controller, "private func refreshTimer()", "private func currentRate()")
        self.assertIn("settledWithoutLyrics", refresh)
        self.assertIn("if settledWithoutLyrics {\n            stopTimer()", refresh)
        self.assertIn("waitingForPlayer ? 5000 : 1000", refresh)
        self.assertIn("hasLines ? 250 : retryIntervalMs", refresh)
        timer = section(self.controller, "private func startTimer(", "private func stopTimer()")
        self.assertIn("intervalMs == 250 ? 50 : 200", timer)
        self.assertNotIn("applicationState", self.controller)
        note = section(self.controller, "func noteNowPlaying(", "func noteCover(")
        self.assertIn("self.timerIntervalMs != 250", note)
        self.assertIn("scheduleMetadataTick()", note)
        self.assertNotIn("self?.tick()", note)
        schedule = section(self.controller, "private func scheduleMetadataTick()", "private func refreshTimer()")
        self.assertIn("guard !metadataTickPending", schedule)
        self.assertIn("DispatchQueue.main.async", schedule)

    def test_stale_previews_and_prewarm_check_install_tokens(self):
        install = section(self.controller, "private func install(", "private func finishInstall(")
        self.assertIn("self.isInstallCurrent(token)", install)
        self.assertIn("self.previewImage(for: artworkID)", install)
        finish = section(self.controller, "private func finishInstall(", "private func prewarmNextLine(")
        self.assertGreaterEqual(finish.count("installToken == token"), 2)
        prewarm = section(self.controller, "private func prewarmNextLine(", "private func artwork(")
        self.assertEqual(prewarm.count("self.isInstallCurrent(token)"), 2)
        self.assertIn("revision: revision", prewarm)

    def test_quality_and_rebase_constants_remain(self):
        for value in ("AVVideoAverageBitRateKey: 2_000_000", "AVVideoMaxKeyFrameIntervalKey: 15",
                      "context.interpolationQuality = .high"):
            self.assertIn(value, self.renderer)
        for value in ("rebaseThresholdMs = 600", "rebaseBucketMs = 500", "LockScreenKaraoke.rebased",
                      "LockScreenKaraoke.frozen"):
            self.assertIn(value, self.controller)
        hashes = (LOCK / "LockScreenLyrics.swift").read_text(encoding="utf-8")
        self.assertIn("scaleKey(textScale)", hashes)
        self.assertIn("scaleKey(spacingScale)", hashes)
        self.assertIn('hasCover ? "c" : "n"', hashes)


if __name__ == "__main__":
    unittest.main()
