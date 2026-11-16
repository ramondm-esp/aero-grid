// SPDX-License-Identifier: GPL-2.0-only
import assert from "node:assert/strict";
import { isDeveloperVersion } from "../../docs/javascripts/radio-installer.mjs";
import { compareVersions } from "../../docs/javascripts/radio-storage.mjs";

export function smokeReleases(catalog) {
  const stable = catalog.releases.filter((entry) => !isDeveloperVersion(entry.version));
  const latest = stable.find((entry) => entry.available && entry.version === catalog.latest);
  const historical = stable.find((entry) => entry.available && compareVersions(entry.version, catalog.latest) < 0);
  assert.ok(latest && historical, "Acceptance requires at least two available mirrored stable releases");
  return { stable, historical };
}

export function githubRelease(entry) {
  const developer = isDeveloperVersion(entry.version);
  const tag = developer ? "dev" : `v${entry.version}`;
  const archive = `AeroGrid-${developer ? "dev" : entry.version}.zip`;
  return {
    tag_name: tag, name: entry.name, draft: false, prerelease: developer,
    assets: entry.available ? [archive, `${archive}.sha256`].map((name) => ({
      name,
      browser_download_url: `https://github.com/thomaskistler/aero-grid/releases/download/${tag}/${name}`,
    })) : [],
  };
}
