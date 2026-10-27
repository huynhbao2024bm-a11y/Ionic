import { Module } from "@nestjs/common";
import { AuthModule } from "../auth/auth.module.js";
import { VideosController } from "./videos.controller.js";
import { VideosService } from "./videos.service.js";

@Module({
  imports: [AuthModule],
  controllers: [VideosController],
  providers: [VideosService],
})
export class VideosModule {}
