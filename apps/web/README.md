# Ionic Angular client — migration reference

This is the previous Ionic + Angular web client. The project is migrating the user-facing app to Flutter in `apps/client` while retaining the same NestJS API and database. Keep this client as a rollback/reference until the Flutter source resolves dependencies, builds, and passes account-backed feed, profile, messaging, and video checks.

## Run the reference client

```powershell
npm install
npm start
```

The Angular development server proxies `/api` to `http://127.0.0.1:3000`; start the API and PostgreSQL as described in [`../api/README.md`](../api/README.md). Use either the Angular dev server or the Flutter proxy at port 4200 at a time. The Flutter startup command and current migration gates are in [`../client/README.md`](../client/README.md) and [`../../docs/ROADMAP.md`](../../docs/ROADMAP.md).
