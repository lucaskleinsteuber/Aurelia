import { pickReleases, label, releasesApi, releasesPage } from "./releases.mjs";

const cacheKey = "tarven.website.releases";
const cacheMinutes = 10;

async function loadReleases() {
  try {
    const cached = JSON.parse(sessionStorage.getItem(cacheKey) ?? "null");
    if (cached && Date.now() - cached.at < cacheMinutes * 60_000) return cached.releases;
  } catch {
    // A damaged cache entry is fetched again.
  }
  const response = await fetch(releasesApi, { headers: { Accept: "application/vnd.github+json" } });
  if (!response.ok) throw new Error(`GitHub answered ${response.status}`);
  const releases = await response.json();
  try {
    sessionStorage.setItem(cacheKey, JSON.stringify({ at: Date.now(), releases }));
  } catch {
    // Without storage the list is simply fetched on every visit.
  }
  return releases;
}

function fill(picked) {
  for (const product of document.querySelectorAll("[data-product]")) {
    const release = picked[product.dataset.product];
    const version = product.querySelector("[data-version]");
    if (!release) {
      version.textContent = "No download yet. See all releases.";
      continue;
    }
    version.textContent = label(release);
    if (release.newerBeta) {
      version.append(document.createElement("br"), `Newer beta: ${release.newerBeta.version} (${release.newerBeta.build})`);
    }
    for (const link of product.querySelectorAll("[data-asset]")) {
      const url = release.assets[link.dataset.asset];
      link.href = url ?? release.page;
    }
  }
}

async function showReleases() {
  const status = document.querySelector("[data-status]");
  try {
    fill(pickReleases(await loadReleases()));
    status.hidden = true;
  } catch {
    status.textContent = "The newest versions couldn't be loaded from GitHub. The download links open the releases page instead.";
    for (const link of document.querySelectorAll("[data-asset]")) link.href = releasesPage;
  }
}

for (const button of document.querySelectorAll("[data-copy]")) {
  button.addEventListener("click", async () => {
    const text = document.getElementById(button.dataset.copy).textContent;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = "Copied";
    } catch {
      button.textContent = "Select and copy";
    }
    setTimeout(() => { button.textContent = "Copy"; }, 2000);
  });
}

showReleases();
