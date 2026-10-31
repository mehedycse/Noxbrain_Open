# NoxBrain Android app

Target: Android 10+। প্রত্যেক ব্যবহারকারীর নিজস্ব Firebase; কোনো shared project নেই। Current source 2.4.32+20432 (firmware source 1.1.38)। Release signing key তৈরি করা আছে (`android/key.properties`, git-ignored); শেষ release হওয়া app 2.4.28 (`releases/app-2.4.28/`), অর্থাৎ এই source-এর APK এখনো package হয়নি। iOS/Desktop provisioning implemented নয়।

## নিজের Firebase প্রস্তুত করা

1. নিজের Firebase Console-এ project তৈরি করুন। Project settings/General-এ Web app register করে config কপি করুন; URL না থাকলে Realtime Database থেকে নিন।
2. Authentication-এর Email/Password provider চালু করুন এবং Users-এ নিজের account তৈরি করুন। App form-এ এই Authentication account-এর email/password লাগবে; Google account password নয়।
3. Realtime Database তৈরি করুন। `../firebase/database.rules.json` Rules tab-এ paste/publish করুন। App-এর setup help একই rules copy করতে পারে। Root public read/write দেবেন না।
4. URL, Web API key, email/password দিয়ে app-এ login যাচাই করুন। Gateway নির্বাচন হলে actual saved ID-এর ownership claim ও scoped read/write হবে। অন্য UID-এর claimed gateway overwrite হবে না।
5. Temporary gateway hotspot দিয়ে home Wi-Fi ও Firebase login একসঙ্গে ESP32-তে যাবে। ESP32 নিজে online হবে; phone Internet থেকে fresh handover যাচাই করবে। তারপর ফোন BLE scan-only এবং ESP32 BLE connection করবে।

এই নির্দেশনা rules publish করার কাজ নিজে করে না। App/ESP32 কোনো central admin service ব্যবহার করে না। Credentials Android Keystore encrypted vault-এ এবং gateway NVS-এ থাকে। ESP32 production flash encryption/secure boot enable করা হয়নি; physical gateway provisioning security আলাদাভাবে release validation-এর বিষয়।

[Firebase password authentication](https://firebase.google.com/docs/auth/web/password-auth), [Realtime Database setup](https://firebase.google.com/docs/database/web/start), [rules](https://firebase.google.com/docs/database/security/core-syntax)।

## Local checks এবং release

`dart analyze lib test` এবং `dart --enable-asserts test/telemetry_contract_check.dart` hardware/network ছাড়া চলে। Flutter tests, Android debug build এবং release Dart/Kotlin compilation পাস করেছে; device tests ও production APK signing বাকি।

Release-এ debug signing নিষিদ্ধ। প্রকাশের অনুমতি পাওয়ার পরে নিজস্ব private keystore-এর `storeFile`, `storePassword`, `keyAlias`, `keyPassword` দিয়ে `android/key.properties` প্রস্তুত করতে হবে। Key/password Git-এ যাবে না; ব্যবহারকারী আগের key ব্যবহার করতে বলেছেন; নতুন key বানানো হয়নি। External properties file `NOXBRAIN_SIGNING_PROPERTIES` অথবা `tools/build_android.ps1 -SigningPropertiesPath` দিয়ে দেওয়া যায়। Relative storeFile path properties file-এর parent থেকে resolve হয়। Firmware assets app-এ bundled নয়; first flash computer-এর website থেকে হবে।

[Full requirements, command/data contract, limits এবং release checks](../README.md)।

## Web view (শুধু দেখা, কোনো setup নেই)

App-এর একটা web version, যেটা নিজের subdomain-এ static file হিসেবে চলে। লিংক থাকলে যে কেউ login ছাড়াই live system দেখতে পারবেন: Home, Statistics, History (CSV download সহ)। চওড়া PC browser-এও app-এর mobile layout দেখাবে (মাঝখানে প্রায় 430 px কলাম, বাকি অংশ app-এর background রঙে); ফোনে পুরো screen জুড়ে দেখাবে। ডিজাইন আর রঙ app-এরই।

**কী করে না:** setup wizard, Firebase change, Connectivity, Smart Switch, General, Update, reset, ফোনে APK update — এগুলো web-এ নেই; এগুলো app থেকেই করতে হবে। কোনো gateway firmware বা Android app-এর আচরণ বদলায়নি।

**Settings ও control:** Settings tab-এ gateway-এর মালিকের Firebase email + password (আর লিংকে `key` না থাকলে Firebase Web API Key) দিয়ে sign in করতে হবে। শুধু যে account এই gateway-এর owner (`gateway_owners/<id>`), তাকেই গ্রহণ করা হয়। Sign in-এর পরে app-এর Controller Parameter tab খোলে: load ON/OFF, charge/discharge switch, battery profile ও parameter, charge current, temperature, load mode, আগের profile restore। Sign in-এর আগে কোনো control দেখায় না। Password সংরক্ষণ হয় না; login শুধু browser tab-এর memory-তে থাকে, ৫৫ মিনিট পর বা tab বন্ধ করলে আবার sign in লাগবে।

**লিংক:** `https://<আপনার-subdomain>/#/v/<Gateway ID>?db=<Database host>`  
Owner-এর sign-in সহজ করতে শেষে `&key=<Firebase Web API Key>` যোগ করা যায় (Web API key গোপন জিনিস নয়, তবে না দিলে sign-in form-এ চাওয়া হবে)। Gateway ID আর Database host app-এর Settings › Diagnostics & Feedback report-এ আছে। Firebase Hosting-এ রাখলে সাইট নিজের প্রজেক্টের database আর API key নিজেই নেয় (`/__/firebase/init.json`), তখন `#/v/<Gateway ID>`-ই যথেষ্ট; আর সাইটের পাশে `site.json` (`{"gateway_id": "…"}`) রাখলে শুধু মূল ঠিকানা খুললেই সেই system দেখায় — তখন ঠিকানা জানা যে কেউ দেখতে পারবেন।

**Privacy:** লিংক যার কাছে আছে সে live মান দেখতে পারবে, কিন্তু কিছু বদলাতে পারবে না। Public হয় শুধু `devices/<id>/live`, `summary`, `lifetime`, `history`। `live`-এর মধ্যে gateway-এর Wi-Fi নাম (বর্তমান ও সংরক্ষিত, password নয়), controller model, battery ধরন/capacity ও controller parameter-ও থাকে, তাই এগুলোও লিংকধারী দেখতে পাবেন। Password, PIN, Bluetooth MAC, `commands`, `command_results`, `setup`, `config`, `gateway_owners` public নয়; gateway-এর তালিকা দেখা যায় না, 28-অক্ষরের ID জানতে হবে। লিংক বন্ধ করতে নিচের read rule সরিয়ে আবার publish করুন।

**একবার Firebase rule publish (মালিক নিজে):** `../firebase/web_view_read_rule.diff` শুধু চারটা `".read": true` লাইন যোগ করে (live, summary, history, lifetime); বাকি কিছু বদলায় না। পুরো rules `../firebase/database.rules.web_view.json`-এ আছে: Firebase Console › Realtime Database › Rules-এ paste করে Publish করুন। এটা না করলে web view সব কিছু Offline দেখাবে (sign in করা owner-এর কাছে অবশ্য দেখাবে)। App-এর setup guide-এর rules (`assets/setup/database.rules.json`) বদলানো হয়নি।

**Build ও hosting:**

```bash
flutter build web --release --base-href / -t lib/main_web.dart
```

`build/web`-এর ভেতরের সব ফাইল যেকোনো static hosting-এ তুললেই চলে (Firebase Hosting, Cloudflare Pages, নিজের server)। কোনো server-side code বা database লাগে না; hash লিংক (`#/v/…`) হওয়ায় rewrite rule লাগে না; HTTPS চালু রাখুন। Hosting-এর নিজস্ব সেটিং (প্রজেক্ট, site, domain) এই repo-তে রাখা হয় না।
