import {
  BadRequestException,
  ConflictException,
  Injectable,
  ServiceUnavailableException,
  UnauthorizedException,
} from "@nestjs/common";
import {
  createHash,
  randomBytes,
  randomUUID,
  scrypt,
  timingSafeEqual,
} from "node:crypto";
import { DatabaseService } from "../database/database.service.js";

const sessionLifetimeMs = 30 * 24 * 60 * 60 * 1000;
const passwordSaltBytes = 16;
const passwordHashBytes = 64;
const fakeSalt = Buffer.alloc(passwordSaltBytes, 0x69);
const fakeHash = Buffer.alloc(passwordHashBytes, 0x6f);

export interface AuthenticatedUser {
  readonly id: string;
  readonly handle: string;
  readonly displayName: string;
}

interface CredentialRow {
  id: string;
  handle: string;
  password_salt: Buffer;
  password_hash: Buffer;
}

interface AccountRow {
  id: string;
  handle: string;
  display_name: string;
}

function derivePassword(password: string, salt: Buffer): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    scrypt(password, salt, passwordHashBytes, (error, derivedKey) => {
      if (error) reject(error);
      else resolve(derivedKey as Buffer);
    });
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireOnlyKeys(input: Record<string, unknown>, allowed: readonly string[]): void {
  if (Object.keys(input).some((key) => !allowed.includes(key))) {
    throw new BadRequestException("Request contains an unsupported field.");
  }
}

function parseRegistration(input: unknown): { handle: string; displayName: string; password: string } {
  if (!isRecord(input)) throw new BadRequestException("Body must be an object.");
  requireOnlyKeys(input, ["handle", "displayName", "password"]);
  const handle = typeof input.handle === "string" ? input.handle.trim().toLowerCase() : "";
  const displayName = typeof input.displayName === "string" ? input.displayName.trim() : "";
  const password = typeof input.password === "string" ? input.password : "";
  if (!/^[a-z0-9_]{3,24}$/.test(handle)) {
    throw new BadRequestException("Handle must use 3–24 lowercase letters, numbers, or underscores.");
  }
  if (displayName.length < 1 || displayName.length > 48) {
    throw new BadRequestException("Display name must contain 1–48 characters.");
  }
  if (password.length < 12 || password.length > 128) {
    throw new BadRequestException("Password must contain 12–128 characters.");
  }
  return { handle, displayName, password };
}

function parseLogin(input: unknown): { handle: string; password: string } {
  if (!isRecord(input)) throw new BadRequestException("Body must be an object.");
  requireOnlyKeys(input, ["handle", "password"]);
  const handle = typeof input.handle === "string" ? input.handle.trim().toLowerCase() : "";
  const password = typeof input.password === "string" ? input.password : "";
  if (!/^[a-z0-9_]{3,24}$/.test(handle) || password.length < 1 || password.length > 128) {
    throw new BadRequestException("Enter a valid handle and password.");
  }
  return { handle, password };
}

function toPublicUser(row: AccountRow): AuthenticatedUser {
  return { id: row.id, handle: row.handle, displayName: row.display_name };
}

function sessionDigest(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

@Injectable()
export class AuthService {
  constructor(private readonly database: DatabaseService) {}

  async register(input: unknown): Promise<{ user: AuthenticatedUser; token: string }> {
    if (process.env.NODE_ENV === "production" && process.env.ALLOW_SIGNUP !== "true") {
      throw new ServiceUnavailableException("Account registration is disabled.");
    }
    const registration = parseRegistration(input);
    const id = randomUUID();
    const salt = randomBytes(passwordSaltBytes);
    const passwordHash = await derivePassword(registration.password, salt);
    const token = randomBytes(32).toString("base64url");
    const expiresAt = new Date(Date.now() + sessionLifetimeMs);

    try {
      const user = await this.database.transaction(async (client) => {
        const account = await client.query<AccountRow>(
          `INSERT INTO app_user (id, handle, handle_normalized, password_salt, password_hash)
           VALUES ($1, $2, $3, $4, $5)
           RETURNING id, handle`,
          [id, registration.handle, registration.handle, salt, passwordHash],
        );
        await client.query(
          "INSERT INTO user_profile (user_id, display_name) VALUES ($1, $2)",
          [id, registration.displayName],
        );
        await client.query(
          "INSERT INTO user_session (token_hash, user_id, expires_at) VALUES ($1, $2, $3)",
          [sessionDigest(token), id, expiresAt],
        );
        return toPublicUser({ ...account.rows[0], display_name: registration.displayName });
      });
      return { user, token };
    } catch (error) {
      if (typeof error === "object" && error !== null && "code" in error && error.code === "23505") {
        throw new ConflictException("That handle is already in use.");
      }
      throw error;
    }
  }

  async login(input: unknown): Promise<{ user: AuthenticatedUser; token: string }> {
    const credentials = parseLogin(input);
    const result = await this.database.query<CredentialRow & { display_name: string }>(
      `SELECT u.id, u.handle, u.password_salt, u.password_hash, p.display_name
       FROM app_user u
       JOIN user_profile p ON p.user_id = u.id
       WHERE u.handle_normalized = $1 AND u.state = 'active'`,
      [credentials.handle],
    );
    const account = result.rows[0];
    const expected = account?.password_hash ?? fakeHash;
    const salt = account?.password_salt ?? fakeSalt;
    const actual = await derivePassword(credentials.password, salt);
    if (account === undefined || !timingSafeEqual(actual, expected)) {
      throw new UnauthorizedException("Handle or password is incorrect.");
    }

    const token = randomBytes(32).toString("base64url");
    const expiresAt = new Date(Date.now() + sessionLifetimeMs);
    await this.database.query(
      `INSERT INTO user_session (token_hash, user_id, expires_at)
       VALUES ($1, $2, $3)
       ON CONFLICT (token_hash) DO NOTHING`,
      [sessionDigest(token), account.id, expiresAt],
    );
    return {
      user: toPublicUser({ id: account.id, handle: account.handle, display_name: account.display_name }),
      token,
    };
  }

  async authenticate(token: string | undefined): Promise<AuthenticatedUser> {
    if (!token || !/^[A-Za-z0-9_-]{40,50}$/.test(token)) {
      throw new UnauthorizedException("Sign in to continue.");
    }
    const result = await this.database.query<AccountRow>(
      `SELECT u.id, u.handle, p.display_name
       FROM user_session s
       JOIN app_user u ON u.id = s.user_id
       JOIN user_profile p ON p.user_id = u.id
       WHERE s.token_hash = $1 AND s.expires_at > now() AND u.state = 'active'`,
      [sessionDigest(token)],
    );
    const account = result.rows[0];
    if (account === undefined) throw new UnauthorizedException("Sign in to continue.");
    return toPublicUser(account);
  }

  async logout(token: string | undefined): Promise<void> {
    if (token && /^[A-Za-z0-9_-]{40,50}$/.test(token)) {
      await this.database.query("DELETE FROM user_session WHERE token_hash = $1", [sessionDigest(token)]);
    }
  }
}

export function readSessionToken(cookieHeader: string | undefined): string | undefined {
  if (!cookieHeader) return undefined;
  for (const part of cookieHeader.split(";")) {
    const [name, ...valueParts] = part.trim().split("=");
    if (name === "ionic_session") return valueParts.join("=");
  }
  return undefined;
}

export function sessionCookie(token: string, maxAgeMs: number): string {
  const secure = process.env.NODE_ENV === "production" ? "; Secure" : "";
  const maxAgeSeconds = Math.floor(maxAgeMs / 1000);
  return `ionic_session=${token}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${maxAgeSeconds}${secure}`;
}

export function clearSessionCookie(): string {
  const secure = process.env.NODE_ENV === "production" ? "; Secure" : "";
  return `ionic_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0${secure}`;
}
