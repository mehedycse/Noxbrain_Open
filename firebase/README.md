# Firebase Realtime Database Setup Guide

This project uses Firebase for secure, real-time synchronization between the ESP32 Gateway and the Flutter mobile app.

Each user or self-hoster creates their own free Firebase project (Spark Plan, 100% free with no credit card required).

## 1. Create a Firebase Project
1. Go to the [Firebase Console](https://console.firebase.google.com/).
2. Click **"Add project"** and give it a name (e.g., `my-solar-monitor`).
3. Google Analytics can be disabled as it is not needed.

## 2. Enable Email/Password Authentication
1. In your Firebase Project console, go to **Build > Authentication**.
2. Click **Get Started**, choose **Email/Password** from Sign-in providers, and enable it.

## 3. Create Realtime Database
1. Go to **Build > Realtime Database**.
2. Click **Create Database**.
3. Choose a database location closest to you (e.g., `Singapore` or `United States`).
4. Select **Start in locked mode**.

## 4. Apply Database Rules
1. In Realtime Database, click on the **Rules** tab.
2. Replace all contents with the rules found in [`database.rules.json`](database.rules.json).
3. Click **Publish**.

> [!NOTE]
> These rules ensure strict multi-tenant isolation: only authenticated accounts can access the gateways they own.
