import { Module } from "@nestjs/common";
import { AuthModule } from "./modules/auth/auth.module.js";
import { DatabaseModule } from "./modules/database/database.module.js";
import { HealthModule } from "./modules/health/health.module.js";
import { MessagesModule } from "./modules/messages/messages.module.js";
import { PostsModule } from "./modules/posts/posts.module.js";
import { ProfilesModule } from "./modules/profiles/profiles.module.js";
import { RecommendationModule } from "./modules/recommendation/recommendation.module.js";
import { VideosModule } from "./modules/videos/videos.module.js";
import { TrustModule } from "./modules/trust/trust.module.js";

@Module({
  imports: [DatabaseModule, HealthModule, AuthModule, PostsModule, ProfilesModule, MessagesModule, VideosModule, RecommendationModule, TrustModule],
})
export class AppModule {}
