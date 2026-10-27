import { BadRequestException, Body, Controller, Get, Param, Patch, Post, Query, Req, UseGuards } from "@nestjs/common";
import { SessionGuard } from "../auth/session.guard.js";
import { RecommendationService } from "./recommendation.service.js";

interface AuthenticatedRequest {
  ionicUser?: { id: string };
}

function parseLimit(value: unknown): number {
  if (value === undefined) return 20;
  if (typeof value !== "string") throw new BadRequestException("Limit is invalid.");
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 50) {
    throw new BadRequestException("Limit must be an integer between 1 and 50.");
  }
  return parsed;
}

@Controller("feed")
@UseGuards(SessionGuard)
export class RecommendationController {
  constructor(private readonly recommendation: RecommendationService) {}

  @Get("for-you")
  forYou(
    @Req() request: AuthenticatedRequest,
    @Query("limit") limit: unknown,
    @Query("cursor") cursor: unknown,
  ) {
    return this.recommendation.forYou(request.ionicUser!.id, parseLimit(limit), cursor);
  }

  @Get("settings")
  settings(@Req() request: AuthenticatedRequest) {
    return this.recommendation.settings(request.ionicUser!.id);
  }

  @Patch("settings")
  updateSettings(@Req() request: AuthenticatedRequest, @Body() body: unknown) {
    return this.recommendation.updateSettings(request.ionicUser!.id, body);
  }

  @Post("reset")
  reset(@Req() request: AuthenticatedRequest) {
    return this.recommendation.reset(request.ionicUser!.id);
  }

  @Post(":contentId/preference")
  setPreference(@Req() request: AuthenticatedRequest, @Param("contentId") contentId: string, @Body() body: unknown) {
    return this.recommendation.setPreference(request.ionicUser!.id, contentId, body);
  }

  @Post(":contentId/hide")
  hide(@Req() request: AuthenticatedRequest, @Param("contentId") contentId: string) {
    return this.recommendation.hide(request.ionicUser!.id, contentId);
  }

  @Post(":contentId/video-signal")
  recordVideoSignal(
    @Req() request: AuthenticatedRequest,
    @Param("contentId") contentId: string,
    @Body() body: unknown,
  ) {
    return this.recommendation.recordVideoSignal(request.ionicUser!.id, contentId, body);
  }
}
