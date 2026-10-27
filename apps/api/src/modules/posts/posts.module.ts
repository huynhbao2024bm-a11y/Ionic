import { Module } from "@nestjs/common";
import { AuthModule } from "../auth/auth.module.js";
import { PostsController, PublicPostsController } from "./posts.controller.js";
import { PostsService } from "./posts.service.js";
import { RecommendationModule } from "../recommendation/recommendation.module.js";

@Module({
  imports: [AuthModule, RecommendationModule],
  controllers: [PostsController, PublicPostsController],
  providers: [PostsService],
})
export class PostsModule {}
