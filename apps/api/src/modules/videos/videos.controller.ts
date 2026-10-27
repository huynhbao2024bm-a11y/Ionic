import { Controller, Get, Param, Post, Req, Res, UseGuards } from "@nestjs/common";
import { createReadStream } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { SessionGuard } from "../auth/session.guard.js";
import { VideosService } from "./videos.service.js";

interface AuthenticatedRequest extends IncomingMessage {
  ionicUser?: { id: string };
}

function parseRange(input: string | string[] | undefined, size: number): { readonly start: number; readonly end: number } | null | "invalid" {
  if (input === undefined) return null;
  const value = Array.isArray(input) ? input[0] : input;
  const match = value?.match(/^bytes=(\d*)-(\d*)$/);
  if (!match || (!match[1] && !match[2])) return "invalid";
  let start: number;
  let end: number;
  if (!match[1]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix < 1) return "invalid";
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else {
    start = Number(match[1]);
    end = match[2] ? Number(match[2]) : size - 1;
  }
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || start >= size) return "invalid";
  return { start, end: Math.min(end, size - 1) };
}

@Controller("videos")
@UseGuards(SessionGuard)
export class VideosController {
  constructor(private readonly videos: VideosService) {}

  @Get()
  list(@Req() request: AuthenticatedRequest) {
    return this.videos.list(request.ionicUser!.id);
  }

  @Post("upload")
  upload(@Req() request: AuthenticatedRequest) {
    return this.videos.upload(request.ionicUser!.id, request, request.headers["x-ionic-caption"]);
  }

  @Get(":contentId/file")
  async file(
    @Req() request: AuthenticatedRequest,
    @Param("contentId") contentId: string,
    @Res() response: ServerResponse,
  ): Promise<void> {
    const asset = await this.videos.playback(request.ionicUser!.id, contentId);
    const range = parseRange(request.headers.range, asset.byteSize);
    response.setHeader("Accept-Ranges", "bytes");
    response.setHeader("Content-Type", asset.mimeType);
    response.setHeader("Cache-Control", "private, no-store");
    response.setHeader("X-Content-Type-Options", "nosniff");
    if (range === "invalid") {
      response.statusCode = 416;
      response.setHeader("Content-Range", `bytes */${asset.byteSize}`);
      response.end();
      return;
    }
    if (range) {
      response.statusCode = 206;
      response.setHeader("Content-Range", `bytes ${range.start}-${range.end}/${asset.byteSize}`);
      response.setHeader("Content-Length", range.end - range.start + 1);
      createReadStream(asset.path, range).on("error", () => response.destroy()).pipe(response);
      return;
    }
    response.statusCode = 200;
    response.setHeader("Content-Length", asset.byteSize);
    createReadStream(asset.path).on("error", () => response.destroy()).pipe(response);
  }
}
