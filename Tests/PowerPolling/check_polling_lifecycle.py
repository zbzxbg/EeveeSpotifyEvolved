#!/usr/bin/env python3
"""Source-level lifecycle regressions; these checks do not replace iOS runtime tests."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "Sources" / "EeveeSpotify"


def source(path):
    return (SRC / path).read_text(encoding="utf-8")


def section(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class PollingLifecycleChecks(unittest.TestCase):
    def test_sleep_uses_wall_one_shot_and_generation_guard(self):
        text = source("Playback/SleepTimer.swift")
        self.assertIn("timer.schedule(wallDeadline:", text)
        self.assertNotIn("repeating:", text)
        self.assertIn("source?.schedule(wallDeadline: .now() + left", text)
        self.assertGreaterEqual(text.count("token == generation"), 2)
        self.assertIn("guard rate > 0", text)

    def test_blocked_artist_stops_without_rules_and_setters_resume(self):
        text = source("Artists/BlockedArtistSkip.swift")
        refresh = section(text, "static func settingsDidChange()", "private static func tick()")
        self.assertIn("guard BlockedArtists.isEnabled, BlockedArtists.count > 0", refresh)
        self.assertLess(refresh.index("timer?.invalidate()"), refresh.index("Timer(timeInterval:"))
        self.assertNotIn("applicationState", text)
        self.assertEqual(source("Shared/Models/Extensions/UserDefaults+Extension.swift").count(
            "BlockedArtistSkip.settingsDidChange()"), 2)

    def test_sponsorblock_idle_gate_retains_future_and_seek_work(self):
        text = source("SponsorBlock/SponsorBlockSkipper.swift")
        work = section(text, "private func hasPollingWork", "private func refreshPolling")
        for item in ("options.enabled", "lastIsPlaying", "seg.isSkip", "minSegmentDuration",
                     ".autoSkip", ".manualSkip", "options.autoSkipMySubmissions"):
            self.assertIn(item, work)
        for item in ("lastPosition", "seg.end", "dismissedUUIDs", "playthroughAllowed",
                     "SponsorBlockHiddenStore"):
            self.assertNotIn(item, work)
        handler = section(text, "t.setEventHandler", "t.resume()")
        self.assertIn("guard options.enabled, self.lastIsPlaying", handler)
        self.assertIn("self.stopPolling()", handler)
        self.assertNotIn("hasPollingWork", handler)
        self.assertNotIn("applicationState", text)

    def test_disabled_sponsorblock_snapshot_remains_fresh_without_fetch_or_seek(self):
        text = source("SponsorBlock/SponsorBlockSkipper.swift")
        process = section(text, "func processStateChange", "func settingsDidChange")
        self.assertNotIn("guard options.enabled else", process)
        self.assertIn("self.lastIsPlaying = isPlaying", process)
        self.assertIn("self.lastPosition = positionSec", process)
        self.assertIn("self.currentEpisodeID = episodeID", process)
        self.assertIn("self.currentSegments = self.mergeWithLocal(serverSegs: []", process)
        self.assertIn("self.currentSegments = []", process)
        fetch = section(text, "private func fetchSegments", "private func seek(player:")
        self.assertIn("guard options.enabled, UserDefaults.sponsorBlockOptions.enabled", fetch)
        check = section(text, "private func checkAndSkip", "private func undoSkip")
        self.assertIn("guard options.enabled, UserDefaults.sponsorBlockOptions.enabled", check)
        settings = section(text, "func settingsDidChange", "private func hasPollingWork")
        self.assertIn("self.fetchSegments(for: episodeID", settings)
        self.assertIn("self.refreshPolling()", settings)
        self.assertIn("SponsorBlockSkipper.shared.settingsDidChange()",
                      source("SponsorBlock/Models/SponsorBlockOptions+UserDefaults.swift"))

    def test_reenable_fetches_server_even_when_local_segments_are_present(self):
        text = source("SponsorBlock/SponsorBlockSkipper.swift")
        process = section(text, "func processStateChange", "func settingsDidChange")
        self.assertIn("self.needsServerFetch = true", process)
        settings = section(text, "func settingsDidChange", "private func hasPollingWork")
        self.assertIn("self.needsServerFetch", settings)
        self.assertIn("!self.emptyEpisodeIDs.contains(episodeID)", settings)
        self.assertNotIn("currentSegments.isEmpty", settings)
        fetch = section(text, "private func fetchSegments", "private func seek(player:")
        self.assertLess(fetch.index("guard options.enabled"), fetch.index("needsServerFetch = false"))
        self.assertLess(fetch.index("episodeID != self.currentEpisodeID"),
                        fetch.index("self.fetchInFlight = false"))
        # Transition model: disabled new episode/local preload keeps the server need;
        # actual fetch consumes it, so subsequent slider changes do not refetch.
        needs_server_fetch = True
        for enabled, cached_empty, in_flight, expected in (
            (False, False, False, False),
            (True, False, False, True),
            (True, False, True, False),
            (True, False, False, False),
        ):
            should_fetch = enabled and needs_server_fetch and not cached_empty and not in_flight
            self.assertEqual(should_fetch, expected)
            if should_fetch:
                needs_server_fetch = False
        needs_server_fetch = True
        cached_empty = True
        self.assertFalse(needs_server_fetch and not cached_empty)

    def test_inline_gating_and_independent_restart_paths(self):
        text = source("Lyrics/CustomLyrics+AllTracksLyrics.x.swift")
        gate = section(text, "private static var hasWatchdogWork", "// MARK: 看门狗")
        for item in ("applicationState == .active", "isWordByWordLyricsEnabled", "hasUsableWordLevelData"):
            self.assertIn(item, gate)
        self.assertIn("UIApplication.didEnterBackgroundNotification", text)
        self.assertIn("UIApplication.didBecomeActiveNotification", text)
        self.assertIn("guard !Watchdog.shared.refreshPending", text)
        self.assertIn("DispatchQueue.main.async", section(text, "static func lyricsDidChange", "private static func observeApplicationLifecycle"))
        self.assertIn("guard let root = resolvedRoot() else {\n                stopWatchdog()", text)
        self.assertIn("didSet { InlineLyricsHostLocator.lyricsDidChange() }",
                      source("Lyrics/WordByWord/WordByWordState.swift"))
        self.assertIn("InlineLyricsHostLocator.lyricsDidChange()",
                      source("Settings/Sections/Lyrics/ViewModels/EeveeLyricsSettingsViewModel.swift"))

    def test_batch_import_and_both_resets_reconcile_once(self):
        text = source("Settings/Models/SettingsBackup.swift")
        self.assertEqual(text.count("refreshFeatureTimers()"), 4)
        refresh = section(text, "private static func refreshFeatureTimers", "// MARK: - 重置")
        for item in ("BlockedArtistSkip.settingsDidChange()", "SponsorBlockSkipper.shared.settingsDidChange()",
                     "InlineLyricsHostLocator.lyricsDidChange()", "ListeningStatsRecorder.shared.settingsDidChange()"):
            self.assertIn(item, refresh)

    def test_stats_keeps_background_sampling_and_pause_baseline(self):
        text = source("Stats/ListeningStatsRecorder.swift")
        self.assertIn("repeating: Self.interval", text)
        self.assertIn("if rate <= 0", text)
        self.assertIn("current.lastPosition = nil", text)
        self.assertIn("current.lastTickAt = nil", text)
        self.assertIn("ListeningStatsRecorder.shared.flushForBackground()", text)


if __name__ == "__main__":
    unittest.main()
