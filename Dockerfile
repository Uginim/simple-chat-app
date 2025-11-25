# Dockerfile - Spring Boot Application
# Multi-stage build로 최적화된 이미지 생성
#
# Stage 1: Build
# Stage 2: Runtime

#############################################
# Stage 1: Build Stage
#############################################
FROM gradle:8.5-jdk17-alpine AS builder

# 작업 디렉토리 설정
WORKDIR /app

# Gradle 캐시 활용을 위해 먼저 의존성 파일만 복사
COPY build.gradle settings.gradle ./
COPY gradle ./gradle

# 의존성 다운로드 (캐싱됨)
RUN gradle dependencies --no-daemon || true

# 소스 코드 복사
COPY src ./src

# 빌드 실행
# - bootJar: 실행 가능한 JAR 생성
# - -x test: 테스트 스킵 (빠른 빌드)
# - --no-daemon: Gradle daemon 사용 안 함 (Docker에서 권장)
RUN gradle bootJar -x test --no-daemon

# 빌드 결과 확인
RUN ls -la /app/build/libs/

#############################################
# Stage 2: Runtime Stage
#############################################
FROM eclipse-temurin:17-jre-alpine

# 메타데이터
LABEL maintainer="your-email@example.com"
LABEL description="Slack-like Chat Application"
LABEL version="1.0.0"

# 보안: root 대신 전용 사용자 생성
RUN addgroup -S spring && adduser -S spring -G spring

# 작업 디렉토리
WORKDIR /app

# builder stage에서 JAR 파일 복사
COPY --from=builder /app/build/libs/*.jar app.jar

# 파일 소유권 변경
RUN chown spring:spring app.jar

# 사용자 전환
USER spring:spring

# JVM 옵션 설정
ENV JAVA_OPTS="\
    -Xms512m \
    -Xmx1024m \
    -XX:+UseContainerSupport \
    -XX:MaxRAMPercentage=75.0 \
    -Djava.security.egd=file:/dev/./urandom \
    -Dspring.profiles.active=docker"

# 애플리케이션 포트
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8080/actuator/health || exit 1

# 애플리케이션 실행
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
