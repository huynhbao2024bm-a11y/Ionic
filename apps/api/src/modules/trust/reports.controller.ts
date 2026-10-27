import { Body, Controller, Post, Req, UseGuards } from "@nestjs/common";
import { SessionGuard } from "../auth/session.guard.js";
import { ReportsService } from "./reports.service.js";

interface AuthenticatedRequest {
  ionicUser?: { id: string };
}

@Controller("reports")
@UseGuards(SessionGuard)
export class ReportsController {
  constructor(private readonly reports: ReportsService) {}

  @Post()
  create(@Req() request: AuthenticatedRequest, @Body() body: unknown) {
    return this.reports.create(request.ionicUser!.id, body);
  }
}
