/* Build verification permits test installation; hardware verification is separate. */
async function verifyNoxBrainRelease(fetchFile, cryptoApi) {
  const get = async path => {
    const response = await fetchFile(path, {cache: "no-store"});
    if (!response.ok) throw new Error("Release file unavailable: " + path);
    return response;
  };
  const release = await (await get("./release.json")).json();
  const manifest = await (await get("./manifest.json")).json();
  if (release.build_verified !== true || manifest.version !== release.version || release.minimum_flash_bytes !== 4194304) throw new Error("Release build verification incomplete");
  const targets = [["ESP32", 0, 4096], ["ESP32-S3", 9, 0]];
  // A release may cover one or both chips; every build must be a known chip.
  if (!Array.isArray(release.artifacts) || !Array.isArray(manifest.builds) || manifest.builds.length < 1 ||
      manifest.builds.some(b => !targets.some(([family]) => family === b.chipFamily))) throw new Error("Incomplete chip builds");
  const paths = new Set();
  for (const [family, chip, boot] of targets.filter(([family]) => manifest.builds.some(b => b.chipFamily === family))) {
    const builds = manifest.builds.filter(b => b.chipFamily === family);
    if (builds.length !== 1 || builds[0].parts?.length !== 4) throw new Error("Missing board image: " + family);
    const offsets = new Set();
    for (const part of builds[0].parts) {
      if (!/^firmware\/[A-Za-z0-9._-]+\.bin$/.test(part.path) || paths.has(part.path)) throw new Error("Invalid artifact path");
      paths.add(part.path);
      const matches = release.artifacts.filter(a => a.path === part.path && a.chip_family === family);
      if (matches.length !== 1) throw new Error("Artifact metadata mismatch");
      const item = matches[0];
      const requiredOffset = {bootloader: boot, partitions: 32768, ota_data: 57344, app: 65536}[item.role];
      if (requiredOffset === undefined || part.offset !== requiredOffset || offsets.has(part.offset)) throw new Error("Wrong flash offset");
      offsets.add(part.offset);
      const data = await (await get("./" + part.path)).arrayBuffer();
      const hash = Array.from(new Uint8Array(await cryptoApi.subtle.digest("SHA-256", data)), b => b.toString(16).padStart(2, "0")).join("");
      if (data.byteLength !== item.size || hash !== item.sha256) throw new Error("Firmware integrity verification failed");
      if (item.role === "app" || item.role === "bootloader") {
        const header = new Uint8Array(data);
        if (data.byteLength < 24 || header[0] !== 233 || (header[12] | header[13] << 8) !== chip || header[3] >> 4 !== 2) throw new Error("Wrong chip/flash image");
      }
      if (item.role === "app" && data.byteLength > 1835008) throw new Error("Firmware exceeds OTA partition");
    }
  }
  if (paths.size !== release.artifacts.length) throw new Error("Unexpected release files");
  return release;
}

if (typeof module !== "undefined") module.exports = {verifyNoxBrainRelease};
if (typeof document !== "undefined") {
  (async () => {
    const status = document.querySelector("#release-status");
    try {
      if (!window.isSecureContext) throw new Error("HTTPS অথবা localhost থেকে flasher খুলুন।");
      const release = await verifyNoxBrainRelease(window.fetch.bind(window), window.crypto);
      const button = document.querySelector("#installer");
      button.setAttribute("manifest", "./manifest.json");
      button.style.display = "";
      document.querySelector("#firmware-version").textContent = "v" + release.version + " · " + release.channel;
      document.querySelector("#firmware-badge").textContent = "Build ও binary যাচাই সম্পন্ন";
      status.textContent = release.hardware_verified ? "যাচাইকৃত firmware · আপনার chip অনুযায়ী install হবে।" : "দুই chip-এর build ও binary যাচাই হয়েছে। বাস্তব setup পরীক্ষা বাকি; এখন test installation করা যাবে। অন্তত 4 MB flash প্রয়োজন।";
    } catch (error) {
      status.textContent = "Install বন্ধ: release যাচাই হয়নি। " + error.message;
    }
  })();
}
