import { Module } from "@nestjs/common";
import { AuthModule } from "../auth/auth.module.js";
import { RecommendationController } from "./recommendation.controller.js";
import { RecommendationService } from "./recommendation.service.js";
import { RecommendationSignalsService } from "./recommendation-signals.service.js";

@Module({
  imports: [AuthModule],
  controllers: [RecommendationController],
  providers: [RecommendationService, RecommendationSignalsService],
  exports: [RecommendationSignalsService],
})
export class RecommendationModule {}
