import { BadRequestException, Body, Controller, Get, Param, Post, Query, Req, UseGuards } from "@nestjs/common";
import { SessionGuard } from "../auth/session.guard.js";
import { MessagesService } from "./messages.service.js";

interface AuthenticatedRequest {
  ionicUser?: { id: string };
}

function parseLimit(value: unknown): number {
  if (value === undefined) return 50;
  if (typeof value !== "string") throw new BadRequestException("Limit is invalid.");
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 50) throw new BadRequestException("Limit must be between 1 and 50.");
  return parsed;
}

@Controller("messages")
@UseGuards(SessionGuard)
export class MessagesController {
  constructor(private readonly messages: MessagesService) {}

  @Get("conversations")
  listConversations(@Req() request: AuthenticatedRequest) {
    return this.messages.listConversations(request.ionicUser!.id);
  }

  @Post("conversations")
  startConversation(@Req() request: AuthenticatedRequest, @Body() body: unknown) {
    if (typeof body !== "object" || body === null || Array.isArray(body)) throw new BadRequestException("Body must be an object.");
    const record = body as Record<string, unknown>;
    if (Object.keys(record).length !== 1 || typeof record.handle !== "string") throw new BadRequestException("Handle is invalid.");
    return this.messages.startConversation(request.ionicUser!.id, record.handle);
  }

  @Get("conversations/:conversationId")
  listMessages(
    @Req() request: AuthenticatedRequest,
    @Param("conversationId") conversationId: string,
    @Query("limit") limit: unknown,
    @Query("cursor") cursor: unknown,
  ) {
    return this.messages.listMessages(request.ionicUser!.id, conversationId, parseLimit(limit), cursor);
  }

  @Post("conversations/:conversationId")
  sendMessage(@Req() request: AuthenticatedRequest, @Param("conversationId") conversationId: string, @Body() body: unknown) {
    return this.messages.sendMessage(request.ionicUser!.id, conversationId, body);
  }
}
