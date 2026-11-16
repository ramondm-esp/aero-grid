// SPDX-License-Identifier: GPL-2.0-only
import assert from "node:assert/strict";
import test from "node:test";
import { githubRelease, smokeReleases } from "./radio-smoke-fixtures.mjs";

const latest = { version: "0.5.0", name: "Latest", available: true };
const old = { version: "0.4.0", name: "Historical", available: true };
const developer = {
  version: "0.6.0-dev.12+aaaaaaaa",
  name: "AeroGrid 0.6.0-dev.12+aaaaaaaa (developer build)", available: true,
};

test("smoke picker excludes developer builds and downgrade pair requires available stable releases", () => {
  const unavailable = { version: "0.3.0", available: false };
  assert.deepEqual(smokeReleases({
    latest: latest.version, releases: [latest, developer, unavailable, old],
  }), { stable: [latest, unavailable, old], historical: old });
  for (const releases of [[latest, developer], [latest, unavailable, developer], [old, developer]]) {
    assert.throws(() => smokeReleases({ latest: latest.version, releases }), /two available mirrored stable/);
  }
});

test("smoke GitHub responses model stable and developer tags, names and archive URLs", () => {
  for (const [entry, tag, archive, prerelease] of [
    [latest, "v0.5.0", "AeroGrid-0.5.0.zip", false],
    [developer, "dev", "AeroGrid-dev.zip", true],
  ]) {
    assert.deepEqual(githubRelease(entry), {
      tag_name: tag, name: entry.name, draft: false, prerelease,
      assets: [archive, `${archive}.sha256`].map((name) => ({
        name, browser_download_url: `https://github.com/thomaskistler/aero-grid/releases/download/${tag}/${name}`,
      })),
    });
    assert.deepEqual(githubRelease({ ...entry, available: false }).assets, []);
  }
});
