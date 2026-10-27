import { Body, Controller, Get, Post, Req, Res, UseGuards } from "@nestjs/common";
import { AuthService, clearSessionCookie, readSessionToken, sessionCookie } from "./auth.service.js";
import { SessionGuard } from "./session.guard.js";

interface HttpRequest {
  readonly headers: { readonly cookie?: string };
}

interface HttpResponse {
  setHeader(name: string, value: string): void;
}

interface AuthenticatedRequest extends HttpRequest {
  ionicUser?: { id: string; handle: string; displayName: string };
}

const sessionLifetimeMs = 30 * 24 * 60 * 60 * 1000;

@Controller("auth")
export class AuthController {
  constructor(private readonly auth: AuthService) {}

  @Post("register")
  async register(
    @Body() body: unknown,
    @Res({ passthrough: true }) response: HttpResponse,
  ): Promise<{ user: { id: string; handle: string; displayName: string } }> {
    const result = await this.auth.register(body);
    response.setHeader("Set-Cookie", sessionCookie(result.token, sessionLifetimeMs));
    return { user: result.user };
  }

  @Post("login")
  async login(
    @Body() body: unknown,
    @Res({ passthrough: true }) response: HttpResponse,
  ): Promise<{ user: { id: string; handle: string; displayName: string } }> {
    const result = await this.auth.login(body);
    response.setHeader("Set-Cookie", sessionCookie(result.token, sessionLifetimeMs));
    return { user: result.user };
  }

  @Post("logout")
  async logout(
    @Req() request: HttpRequest,
    @Res({ passthrough: true }) response: HttpResponse,
  ): Promise<{ status: "signed_out" }> {
    await this.auth.logout(readSessionToken(request.headers.cookie));
    response.setHeader("Set-Cookie", clearSessionCookie());
    return { status: "signed_out" };
  }

  @Get("me")
  @UseGuards(SessionGuard)
  getCurrentUser(@Req() request: AuthenticatedRequest): { user: NonNullable<AuthenticatedRequest["ionicUser"]> } {
    return { user: request.ionicUser! };
  }
}
