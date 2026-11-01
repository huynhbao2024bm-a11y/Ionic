FROM dart:3.13.7-sdk AS build
WORKDIR /app/apps/server
COPY apps/server/pubspec.yaml apps/server/pubspec.lock ./
RUN dart pub get --enforce-lockfile
COPY apps/server/lib ./lib
COPY apps/server/bin ./bin
RUN mkdir -p /out && dart compile exe lib/main.dart -o /out/api \
 && dart compile exe bin/migrate.dart -o /out/migrate \
 && dart compile exe bin/cleanup_recommendation.dart -o /out/cleanup-recommendation \
 && dart compile exe bin/cleanup_media.dart -o /out/cleanup-media

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /etc/ssl/certs /etc/ssl/certs
COPY --from=build /out/ /app/apps/server/bin/
COPY apps/api/migrations /app/apps/api/migrations
COPY infra/supabase/prod-ca-2021.crt /app/infra/supabase/prod-ca-2021.crt
WORKDIR /app/apps/server
ENV APP_ENV=production HOST=0.0.0.0 PORT=10000 \
    IONIC_ATTACHMENT_STORAGE=supabase \
    RECOMMENDATION_ADAPTIVE_ENABLED=true \
    RECOMMENDATION_MIN_RANDOM_SHARE=0.40 \
    RECOMMENDATION_SEMANTIC_ENABLED=false
USER 10001
EXPOSE 10000
CMD ["/app/apps/server/bin/api"]
