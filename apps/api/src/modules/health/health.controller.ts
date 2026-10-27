import { Controller, Get, HttpStatus, Res } from "@nestjs/common";
import { DatabaseReadiness, DatabaseService } from "../database/database.service.js";

interface HttpStatusResponse {
  status(code: number): HttpStatusResponse;
}

@Controller("health")
export class HealthController {
  constructor(private readonly database: DatabaseService) {}

  @Get("live")
  getLiveness(): { status: "ok" } {
    return { status: "ok" };
  }

  @Get("ready")
  async getReadiness(
    @Res({ passthrough: true }) response: HttpStatusResponse,
  ): Promise<{ status: "ready" | "not_ready"; dependencies: { database: DatabaseReadiness } }> {
    const database = await this.database.checkReadiness();
    if (database !== "ready") {
      response.status(HttpStatus.SERVICE_UNAVAILABLE);
    }

    return {
      status: database === "ready" ? "ready" : "not_ready",
      dependencies: { database },
    };
  }
}
