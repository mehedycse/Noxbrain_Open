# NoxBrain website flasher · 1.1.25 candidate

ESP32-S3 firmware build, chip header/checksum/image hash, common 4MB partition এবং SHA-256 যাচাই সম্পন্ন। `release.json`-এ `build_verified=true`, `hardware_verified=false`, `verified=false`। এটি test installation-এর জন্য candidate; hardware-tested production certification নয়।

`index.html` → `release-loader.js` বর্তমান manifest ও তার চারটি file-এর hash/size/chip/offset যাচাই করে তারপর Install দেখাবে। Wrong chip, missing/corrupt image বা metadata mismatch হলে Install বন্ধ থাকবে। ESP Web Tools 10.4.0 pin করা আছে।

User flow: computer + data USB cable → HTTPS website Chrome/Edge → chip অনুযায়ী flash → ESP32 নিজে `NoxBrain-…` setup Wi-Fi চালু করে → ফোনের নিজের Wi-Fi settings থেকে যুক্ত হওয়া (সব gateway-এর password `85208136`, পাতায় লেখা) → Android app Setup Wizard। Phone USB-OTG flashing নেই, setup code নেই। Setup Wi-Fi খোলে শুধু নতুন gateway-এ অথবা BOOT বোতাম ১ সেকেন্ডে ৩ বার চাপলে (২০ মিনিট); Wi-Fi বা বিদ্যুৎ চলে গেলে নিজে খোলে না।

দুই target-এর minimum flash **4MB**; larger 8/16MB chips-এ একই lower 4MB layout ব্যবহার হয়। ESP32 bootloader offset 0x1000, ESP32-S3 0x0; partition 0x8000, boot_app0 0xE000, app 0x10000। App0/app1 প্রত্যেকটি 0x1C0000 bytes। আলাদা parts flash হয়; NVS 0x9000..0xDFFF package write regions-এর বাইরে। Default erase false। Partition/layout migration-এ পুরোনো local history filesystem অন্য address-এ থাকলে সেটি নিজে migrate হয় না।

প্রস্তুত ZIP: `../releases/firmware-<version>/NoxBrain_WebFlasher_<version>.zip`, VPS-এ (`https://noxbrain.com/solarapp/`) এর contents দিতে হবে। Firmware OTA-র জন্য একই release-এর `github_ota/` folder GitHub `mehedycse/noxbrain_espupdate`-এ যাবে। Website-এ Firebase বা Wi-Fi credentials নেই। পুরোনো loose binary, deploy_* ও ZIP প্রকাশ করবেন না।

Repackage: `python tools/package_release.py firmware --notes "…"`। এটি stale build, wrong chip/hash/partition অথবা NVS-overlapping regions reject করে। `node web_flasher/test-release.cjs` বর্তমান artifacts ও corrupt/wrong-chip rejection পরীক্ষা করে।

[সম্পূর্ণ architecture ও remaining checks](../README.md)।
