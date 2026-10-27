import { CanActivate, ExecutionContext, Injectable } from "@nestjs/common";
import { AuthService, readSessionToken } from "./auth.service.js";

interface AuthenticatedRequest {
  readonly headers: { readonly cookie?: string };
  ionicUser?: { id: string; handle: string; displayName: string };
}

@Injectable()
export class SessionGuard implements CanActivate {
  constructor(private readonly auth: AuthService) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest<AuthenticatedRequest>();
    request.ionicUser = await this.auth.authenticate(readSessionToken(request.headers.cookie));
    return true;
  }
}
