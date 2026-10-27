import { Body, Controller, Delete, Get, Param, Patch, Post, Query, Req, UseGuards } from "@nestjs/common";
import { SessionGuard } from "../auth/session.guard.js";
import { ProfilesService } from "./profiles.service.js";

interface AuthenticatedRequest {
  ionicUser?: { id: string; handle: string };
}

@Controller("profiles")
@UseGuards(SessionGuard)
export class ProfilesController {
  constructor(private readonly profiles: ProfilesService) {}

  @Patch("me")
  async updateMe(@Req() request: AuthenticatedRequest, @Body() body: unknown) {
    const profile = await this.profiles.updateMe(request.ionicUser!.id, body);
    return {
      user: {
        id: request.ionicUser!.id,
        handle: request.ionicUser!.handle,
        displayName: profile.displayName,
      },
      profile,
    };
  }

  @Get("search")
  search(@Req() request: AuthenticatedRequest, @Query("q") query: unknown) {
    return this.profiles.search(request.ionicUser!.id, query ?? "");
  }

  @Get("following")
  listFollowing(@Req() request: AuthenticatedRequest) {
    return this.profiles.listFollowing(request.ionicUser!.id);
  }

  @Get("blocked")
  listBlocked(@Req() request: AuthenticatedRequest) {
    return this.profiles.listBlocked(request.ionicUser!.id);
  }

  @Get("muted")
  listMuted(@Req() request: AuthenticatedRequest) {
    return this.profiles.listMuted(request.ionicUser!.id);
  }

  @Post(":handle/follow")
  follow(@Req() request: AuthenticatedRequest, @Param("handle") handle: string) {
    return this.profiles.follow(request.ionicUser!.id, handle);
  }

  @Delete(":handle/follow")
  unfollow(@Req() request: AuthenticatedRequest, @Param("handle") handle: string) {
    return this.profiles.unfollow(request.ionicUser!.id, handle);
  }

  @Post(":handle/block")
  block(@Req() request: AuthenticatedRequest, @Param("handle") handle: string) {
    return this.profiles.block(request.ionicUser!.id, handle);
  }

  @Delete(":handle/block")
  unblock(@Req() request: AuthenticatedRequest, @Param("handle") handle: string) {
    return this.profiles.unblock(request.ionicUser!.id, handle);
  }

  @Post(":handle/mute")
  mute(@Req() request: AuthenticatedRequest, @Param("handle") handle: string) {
    return this.profiles.mute(request.ionicUser!.id, handle);
  }

  @Delete(":handle/mute")
  unmute(@Req() request: AuthenticatedRequest, @Param("handle") handle: string) {
    return this.profiles.unmute(request.ionicUser!.id, handle);
  }

  @Get(":handle")
  getProfile(@Req() request: AuthenticatedRequest, @Param("handle") handle: string) {
    return this.profiles.getProfile(request.ionicUser!.id, handle);
  }
}
