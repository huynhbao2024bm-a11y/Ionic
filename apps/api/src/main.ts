import "reflect-metadata";
import { NestFactory } from "@nestjs/core";
import { AppModule } from "./app.module.js";
import { SameOriginWriteGuard } from "./modules/auth/same-origin-write.guard.js";

function readPort(value: string | undefined): number {
  const port = value === undefined ? 3000 : Number(value);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) {
    throw new Error("PORT must be an integer between 1 and 65535.");
  }
  return port;
}

async function bootstrap(): Promise<void> {
  const app = await NestFactory.create(AppModule);
  const allowedOrigins = new Set(
    (process.env.WEB_ORIGINS ?? "http://127.0.0.1:4200")
      .split(",")
      .map((origin) => origin.trim())
      .filter(Boolean),
  );

  app.setGlobalPrefix("api/v1");
  app.enableCors({
    origin: [...allowedOrigins],
    credentials: true,
    methods: ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allowedHeaders: ["Content-Type", "X-CSRF-Token", "X-Ionic-Caption"],
  });
  app.useGlobalGuards(new SameOriginWriteGuard(allowedOrigins));
  app.enableShutdownHooks();

  const host = process.env.HOST ?? (process.env.NODE_ENV === "production" ? "0.0.0.0" : "127.0.0.1");
  await app.listen(readPort(process.env.PORT), host);
}

void bootstrap();
