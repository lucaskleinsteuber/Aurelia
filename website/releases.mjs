// Picks the download for each product from GitHub's release list.
// Pure logic without the DOM, so tests/Website can check it.

export const repository = "lucaskleinsteuber/Tarven";
export const releasesPage = `https://github.com/${repository}/releases`;
export const releasesApi = `https://api.github.com/repos/${repository}/releases?per_page=100`;

const version = "(\\d+\\.\\d+\\.\\d+)-(\\d+)";

export const products = {
  mac: {
    tag: new RegExp(`^${version}$`),
    assets: {
      arm64: /^Tarven-[\d.]+-\d+-macOS-arm64\.dmg$/,
      x64: /^Tarven-[\d.]+-\d+-macOS-x64\.dmg$/,
    },
  },
  linux: {
    tag: new RegExp(`^linux-app-${version}$`),
    assets: {
      debX64: /^Tarven-Desktop-[\d.]+-\d+-amd64\.deb$/,
      debArm64: /^Tarven-Desktop-[\d.]+-\d+-arm64\.deb$/,
      rpmX64: /^Tarven-Desktop-[\d.]+-\d+-x86_64\.rpm$/,
      rpmArm64: /^Tarven-Desktop-[\d.]+-\d+-aarch64\.rpm$/,
      archX64: /^Tarven-Desktop-[\d.]+-\d+-x86_64\.pkg\.tar\.zst$/,
      archArm64: /^Tarven-Desktop-[\d.]+-\d+-aarch64\.pkg\.tar\.zst$/,
      flatpakX64: /^Tarven-Desktop-[\d.]+-\d+-x86_64\.flatpak$/,
    },
  },
  server: {
    tag: new RegExp(`^server-${version}$`),
    assets: {
      x64: /^Tarven-Server-[\d.]+-\d+-linux-x64\.tar\.gz$/,
      arm64: /^Tarven-Server-[\d.]+-\d+-linux-arm64\.tar\.gz$/,
    },
  },
};

function describe(release, product) {
  const match = product.tag.exec(release.tag_name ?? "");
  if (!match || release.draft) return null;
  const assets = {};
  for (const [key, pattern] of Object.entries(product.assets)) {
    const asset = (release.assets ?? []).find((candidate) => pattern.test(candidate.name));
    if (asset) assets[key] = asset.browser_download_url;
  }
  if (Object.keys(assets).length === 0) return null;
  return {
    version: match[1],
    build: Number(match[2]),
    beta: Boolean(release.prerelease),
    page: release.html_url,
    assets,
  };
}

// For each product: the newest stable release with Tarven downloads, or the newest beta when
// there is no stable one yet. A beta newer than the chosen stable release is returned as
// `newerBeta`. The build number orders releases, because it rises with every build.
export function pickReleases(releases) {
  const picked = {};
  for (const [name, product] of Object.entries(products)) {
    const candidates = releases
      .map((release) => describe(release, product))
      .filter(Boolean)
      .sort((a, b) => b.build - a.build);
    const stable = candidates.find((candidate) => !candidate.beta);
    const newest = candidates[0];
    if (!newest) {
      picked[name] = null;
    } else if (stable) {
      picked[name] = { ...stable, newerBeta: newest.beta ? newest : null };
    } else {
      picked[name] = { ...newest, newerBeta: null };
    }
  }
  return picked;
}

export function label(release) {
  return `Version ${release.version} (${release.build})${release.beta ? ", beta" : ""}`;
}
