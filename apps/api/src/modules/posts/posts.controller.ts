import { BadRequestException, Body, Controller, Delete, Get, Param, Post, Query, Req, UseGuards } from "@nestjs/common";
import { SessionGuard } from "../auth/session.guard.js";
import { parsePostsCursor, PostsService } from "./posts.service.js";

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

@Controller("posts")
export class PublicPostsController {
  constructor(private readonly posts: PostsService) {}

  @Get("public")
  listPublic(
    @Query("limit") limit: unknown,
    @Query("cursor") cursor: unknown,
  ) {
    return this.posts.listPublic(parseLimit(limit), parsePostsCursor(cursor));
  }
}

@Controller("posts")
@UseGuards(SessionGuard)
export class PostsController {
  constructor(private readonly posts: PostsService) {}

  @Post()
  create(
    @Req() request: AuthenticatedRequest,
    @Body() body: unknown,
  ) {
    return this.posts.create(request.ionicUser!.id, body);
  }

  @Get("mine")
  listMine(
    @Req() request: AuthenticatedRequest,
    @Query("limit") limit: unknown,
    @Query("cursor") cursor: unknown,
  ) {
    return this.posts.listMine(request.ionicUser!.id, parseLimit(limit), parsePostsCursor(cursor));
  }

  @Get("following")
  listFollowing(
    @Req() request: AuthenticatedRequest,
    @Query("limit") limit: unknown,
    @Query("cursor") cursor: unknown,
  ) {
    return this.posts.listFollowing(request.ionicUser!.id, parseLimit(limit), parsePostsCursor(cursor));
  }

  @Get("search")
  search(
    @Req() request: AuthenticatedRequest,
    @Query("q") query: unknown,
    @Query("limit") limit: unknown,
    @Query("cursor") cursor: unknown,
  ) {
    return this.posts.search(request.ionicUser!.id, query, parseLimit(limit), parsePostsCursor(cursor));
  }

  @Get("author/:handle")
  listAuthorPosts(
    @Req() request: AuthenticatedRequest,
    @Param("handle") handle: string,
    @Query("limit") limit: unknown,
    @Query("cursor") cursor: unknown,
  ) {
    return this.posts.listAuthor(request.ionicUser!.id, handle, parseLimit(limit), parsePostsCursor(cursor));
  }

  @Post(":contentId/like")
  like(@Req() request: AuthenticatedRequest, @Param("contentId") contentId: string) {
    return this.posts.setLike(request.ionicUser!.id, contentId, true);
  }

  @Delete(":contentId/like")
  unlike(@Req() request: AuthenticatedRequest, @Param("contentId") contentId: string) {
    return this.posts.setLike(request.ionicUser!.id, contentId, false);
  }

  @Post(":contentId/save")
  save(@Req() request: AuthenticatedRequest, @Param("contentId") contentId: string) {
    return this.posts.setSaved(request.ionicUser!.id, contentId, true);
  }

  @Delete(":contentId/save")
  unsave(@Req() request: AuthenticatedRequest, @Param("contentId") contentId: string) {
    return this.posts.setSaved(request.ionicUser!.id, contentId, false);
  }

  @Post(":contentId/replies")
  reply(@Req() request: AuthenticatedRequest, @Param("contentId") contentId: string, @Body() body: unknown) {
    return this.posts.addReply(request.ionicUser!.id, contentId, body);
  }

  @Get(":contentId/replies")
  replies(
    @Req() request: AuthenticatedRequest,
    @Param("contentId") contentId: string,
    @Query("limit") limit: unknown,
    @Query("cursor") cursor: unknown,
  ) {
    return this.posts.listReplies(request.ionicUser!.id, contentId, parseLimit(limit), parsePostsCursor(cursor));
  }
}
