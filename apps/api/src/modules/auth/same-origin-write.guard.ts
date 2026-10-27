import { CanActivate, ExecutionContext, ForbiddenException, Injectable } from "@nestjs/common";

interface OriginRequest {
  readonly method: string;
  readonly headers: { readonly origin?: string };
}

@Injectable()
export class SameOriginWriteGuard implements CanActivate {
  constructor(private readonly allowedOrigins: ReadonlySet<string>) {}

  canActivate(context: ExecutionContext): boolean {
    const request = context.switchToHttp().getRequest<OriginRequest>();
    if (["GET", "HEAD", "OPTIONS"].includes(request.method.toUpperCase())) return true;

    const origin = request.headers.origin;
    if (origin === undefined || this.allowedOrigins.has(origin)) return true;
    throw new ForbiddenException("Request origin is not allowed.");
  }
}
