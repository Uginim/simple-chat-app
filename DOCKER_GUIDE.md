# Docker 구성 가이드

> **목적**: Docker를 사용해 개발/프로덕션 환경을 쉽게 구축
> **난이도**: ⭐⭐ (초급~중급)

---

## 📚 목차

1. [Docker 개요](#1-docker-개요)
2. [개발 환경 구성](#2-개발-환경-구성)
3. [프로덕션 환경 구성](#3-프로덕션-환경-구성)
4. [사용 시나리오](#4-사용-시나리오)
5. [트러블슈팅](#5-트러블슈팅)
6. [유용한 명령어](#6-유용한-명령어)

---

## 1. Docker 개요

### 1.1 왜 Docker를 사용하는가?

```
[임베디드 모드 vs Docker 비교]

❌ 임베디드 모드 (Phase 1 기본)
┌─────────────────────────────┐
│  Spring Boot Application    │
│  ├─ H2 (인메모리)           │
│  ├─ Artemis (내장)          │
│  └─ Caffeine Cache          │
└─────────────────────────────┘

문제점:
- 재시작 시 데이터 손실
- 프로덕션 환경과 다름
- 팀원마다 설정 다름

✅ Docker 구성
┌──────────┐ ┌──────────┐ ┌──────────┐
│ App      │ │Postgres  │ │ Artemis  │
│ (8080)   │ │ (5432)   │ │ (61616)  │
└──────────┘ └──────────┘ └──────────┘

장점:
- 데이터 영구 저장
- 프로덕션과 동일한 환경
- 팀원 간 환경 통일
- 서비스별 독립적 관리
```

### 1.2 구성 파일 설명

```
simple-chat-app/
├── Dockerfile                    # Spring Boot 이미지 빌드
├── .dockerignore                 # Docker 빌드 시 제외 파일
├── docker-compose.yml            # 개발 환경 (추천)
├── docker-compose.prod.yml       # 프로덕션 환경
└── src/main/resources/
    ├── application.yml           # 기본 설정
    └── application-docker.yml    # Docker 환경 설정
```

---

## 2. 개발 환경 구성

### 2.1 전제 조건

**Docker 설치 확인**:
```bash
docker --version
# Docker version 24.0.0 이상

docker-compose --version
# Docker Compose version v2.20.0 이상
```

**미설치 시**:
- Windows/Mac: [Docker Desktop](https://www.docker.com/products/docker-desktop/)
- Linux:
  ```bash
  curl -fsSL https://get.docker.com -o get-docker.sh
  sudo sh get-docker.sh
  ```

### 2.2 시나리오 1: DB/Artemis만 Docker (추천)

**장점**:
- 빠른 개발 (코드 수정 시 재빌드 불필요)
- IDE 디버깅 가능
- 로그 보기 쉬움

**구성**:
```
Docker:      PostgreSQL + Artemis + Redis
로컬:        Spring Boot (IntelliJ/VS Code)
```

#### Step 1: Docker 서비스 시작

```bash
# 프로젝트 루트에서
cd /home/user/simple-chat-app

# Docker 서비스 시작 (백그라운드)
docker-compose up -d postgres artemis redis

# 로그 확인
docker-compose logs -f

# 서비스 상태 확인
docker-compose ps
```

**예상 출력**:
```
NAME                 IMAGE                              STATUS        PORTS
chat-postgres        postgres:15-alpine                 Up (healthy)  0.0.0.0:5432->5432/tcp
chat-artemis         apache/activemq-artemis:2.31.2     Up (healthy)  0.0.0.0:61616->61616/tcp, 0.0.0.0:8161->8161/tcp
chat-redis           redis:7-alpine                     Up (healthy)  0.0.0.0:6379->6379/tcp
```

#### Step 2: application.yml 수정

**파일**: `src/main/resources/application.yml`

```yaml
spring:
  profiles:
    active: docker  # Docker 프로필 활성화

  datasource:
    url: jdbc:postgresql://localhost:5432/chatdb  # Docker → 로컬
    username: chatuser
    password: chatpass

  artemis:
    mode: native
    broker-url: tcp://localhost:61616  # Docker → 로컬
    user: admin
    password: admin
```

#### Step 3: Spring Boot 실행

```bash
# Gradle 사용
./gradlew bootRun --args='--spring.profiles.active=docker'

# 또는 IntelliJ에서
# Run → Edit Configurations → VM options: -Dspring.profiles.active=docker
```

#### Step 4: 서비스 접속 확인

**1. PostgreSQL 접속**:
```bash
docker exec -it chat-postgres psql -U chatuser -d chatdb

# 테이블 조회
\dt

# 종료
\q
```

**2. Artemis Web Console**:
```
URL: http://localhost:8161/console
ID: admin
PW: admin
```

**3. Redis 접속**:
```bash
docker exec -it chat-redis redis-cli

# 테스트
PING
# 응답: PONG

# 종료
exit
```

#### Step 5: 개발 완료 후 정리

```bash
# 서비스 중지 (데이터 유지)
docker-compose stop

# 서비스 중지 + 컨테이너 삭제 (데이터 유지)
docker-compose down

# 서비스 중지 + 컨테이너 삭제 + 데이터 삭제
docker-compose down -v
```

---

### 2.3 시나리오 2: 전체 Docker 구성

**장점**:
- 프로덕션과 동일한 환경
- 팀원 간 환경 통일
- 배포 전 테스트

**단점**:
- 코드 수정 시 재빌드 필요
- 디버깅 어려움

#### Step 1: docker-compose.yml 수정

**파일**: `docker-compose.yml`

app 서비스 주석 해제:
```yaml
services:
  # ... postgres, artemis, redis ...

  app:  # 주석 해제
    build:
      context: .
      dockerfile: Dockerfile
    # ... (나머지 설정)
```

#### Step 2: 전체 빌드 및 실행

```bash
# 이미지 빌드 + 실행
docker-compose up --build -d

# 로그 확인 (app 서비스만)
docker-compose logs -f app

# 모든 서비스 로그
docker-compose logs -f
```

#### Step 3: 애플리케이션 접속

```bash
# Health check
curl http://localhost:8080/actuator/health

# API 테스트
curl http://localhost:8080/api/workspaces \
  -H "Authorization: Bearer YOUR_JWT_TOKEN"
```

#### Step 4: 코드 수정 후 재빌드

```bash
# 코드 수정 후
docker-compose up --build -d app

# 또는 개별 재빌드
docker-compose build app
docker-compose up -d app
```

---

## 3. 프로덕션 환경 구성

### 3.1 환경 변수 설정

#### Step 1: .env 파일 생성

**파일**: `.env` (프로젝트 루트)

```bash
# .env
# ⚠️ Git에 커밋하지 말 것! (.gitignore에 추가)

# Database
DB_NAME=chatdb
DB_USER=chatuser
DB_PASSWORD=YOUR_STRONG_PASSWORD_HERE

# Artemis
ARTEMIS_USER=admin
ARTEMIS_PASSWORD=YOUR_ARTEMIS_PASSWORD

# Redis
REDIS_PASSWORD=YOUR_REDIS_PASSWORD

# JWT
JWT_SECRET=YOUR_256_BIT_SECRET_KEY_CHANGE_THIS
JWT_EXPIRATION=3600000

# Google OAuth
GOOGLE_CLIENT_ID=your-client-id.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=YOUR_GOOGLE_SECRET
GOOGLE_REDIRECT_URI=https://your-domain.com/api/auth/google/callback

# Application
APP_PORT=8080
APP_REPLICAS=2

# Build Info
VERSION=1.0.0
BUILD_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
```

#### Step 2: .gitignore 업데이트

```bash
# .gitignore에 추가
.env
.env.*
!.env.example
```

#### Step 3: .env.example 생성 (팀 공유용)

```bash
# .env.example
DB_NAME=chatdb
DB_USER=chatuser
DB_PASSWORD=CHANGE_THIS
ARTEMIS_PASSWORD=CHANGE_THIS
REDIS_PASSWORD=CHANGE_THIS
JWT_SECRET=CHANGE_THIS_256_BIT_KEY
# ...
```

### 3.2 프로덕션 배포

#### Step 1: 서버 준비

```bash
# 프로젝트 클론
git clone https://github.com/your-username/simple-chat-app.git
cd simple-chat-app

# .env 파일 생성 및 수정
cp .env.example .env
nano .env  # 실제 값 입력
```

#### Step 2: 데이터 디렉토리 생성

```bash
# 영구 저장 경로 생성
sudo mkdir -p /data/postgres
sudo mkdir -p /data/artemis
sudo mkdir -p /data/redis

# 권한 설정
sudo chown -R 999:999 /data/postgres  # PostgreSQL UID
sudo chown -R 1000:1000 /data/artemis
sudo chown -R 999:999 /data/redis
```

#### Step 3: 프로덕션 배포

```bash
# 프로덕션 compose 파일 사용
docker-compose -f docker-compose.prod.yml up -d

# 로그 확인
docker-compose -f docker-compose.prod.yml logs -f

# 상태 확인
docker-compose -f docker-compose.prod.yml ps
```

#### Step 4: Health Check

```bash
# PostgreSQL
docker exec chat-postgres-prod pg_isready -U chatuser

# Artemis
curl http://localhost:8161/

# Application
curl http://localhost:8080/actuator/health
```

### 3.3 모니터링 및 로그

```bash
# 실시간 로그
docker-compose -f docker-compose.prod.yml logs -f app

# 최근 100줄
docker-compose -f docker-compose.prod.yml logs --tail=100 app

# 컨테이너 리소스 사용량
docker stats

# 특정 컨테이너 상세 정보
docker inspect chat-app-prod
```

---

## 4. 사용 시나리오

### 4.1 새 팀원 온보딩

```bash
# 1. 프로젝트 클론
git clone https://github.com/your-username/simple-chat-app.git
cd simple-chat-app

# 2. Docker 인프라 시작
docker-compose up -d postgres artemis redis

# 3. Spring Boot 실행
./gradlew bootRun --args='--spring.profiles.active=docker'

# 완료! 개발 환경 준비됨
```

### 4.2 DB 스키마 초기화

```bash
# PostgreSQL 컨테이너 접속
docker exec -it chat-postgres psql -U chatuser -d chatdb

# 모든 테이블 삭제
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;

# Spring Boot 재시작 (JPA가 스키마 재생성)
./gradlew bootRun --args='--spring.profiles.active=docker'
```

### 4.3 DB 백업 및 복원

**백업**:
```bash
# PostgreSQL 덤프
docker exec chat-postgres pg_dump -U chatuser chatdb > backup.sql

# 또는 압축
docker exec chat-postgres pg_dump -U chatuser chatdb | gzip > backup.sql.gz
```

**복원**:
```bash
# 압축 해제 및 복원
gunzip < backup.sql.gz | docker exec -i chat-postgres psql -U chatuser -d chatdb

# 또는 직접
docker exec -i chat-postgres psql -U chatuser -d chatdb < backup.sql
```

### 4.4 Artemis 큐 초기화

```bash
# Artemis 컨테이너 재시작 (인메모리 큐 초기화)
docker-compose restart artemis

# 또는 데이터까지 삭제
docker-compose stop artemis
docker volume rm simple-chat-app_artemis-data
docker-compose up -d artemis
```

---

## 5. 트러블슈팅

### 문제 1: 포트 충돌

**증상**:
```
Error: bind: address already in use
```

**해결**:
```bash
# 사용 중인 포트 확인
lsof -i :5432  # PostgreSQL
lsof -i :61616 # Artemis
lsof -i :8080  # Application

# 프로세스 종료
kill -9 <PID>

# 또는 docker-compose.yml에서 포트 변경
ports:
  - "15432:5432"  # 5432 대신 15432 사용
```

### 문제 2: 볼륨 권한 문제

**증상**:
```
Permission denied: /var/lib/postgresql/data
```

**해결**:
```bash
# 볼륨 권한 확인
docker volume inspect simple-chat-app_postgres-data

# 컨테이너 재생성 (볼륨 삭제)
docker-compose down -v
docker-compose up -d
```

### 문제 3: 네트워크 연결 실패

**증상**:
```
Could not connect to PostgreSQL: Connection refused
```

**해결**:
```bash
# 컨테이너가 같은 네트워크에 있는지 확인
docker network inspect simple-chat-app_chat-network

# 네트워크 재생성
docker-compose down
docker network prune
docker-compose up -d
```

### 문제 4: 이미지 빌드 실패

**증상**:
```
ERROR: failed to solve: process "/bin/sh -c gradle bootJar" did not complete successfully
```

**해결**:
```bash
# Docker 캐시 삭제 후 재빌드
docker-compose build --no-cache app

# 로컬에서 먼저 빌드 확인
./gradlew clean build

# 빌드 로그 상세히 보기
docker-compose build app 2>&1 | tee build.log
```

### 문제 5: 메모리 부족

**증상**:
```
OutOfMemoryError: Java heap space
```

**해결**:

**방법 1**: `docker-compose.yml` 수정
```yaml
app:
  environment:
    JAVA_OPTS: "-Xms512m -Xmx2048m"
```

**방법 2**: Docker 메모리 늘리기 (Docker Desktop)
```
Settings → Resources → Memory → 4GB 이상
```

---

## 6. 유용한 명령어

### 6.1 Docker Compose 명령어

```bash
# 시작
docker-compose up -d

# 중지
docker-compose stop

# 재시작
docker-compose restart

# 특정 서비스만 재시작
docker-compose restart app

# 로그 보기
docker-compose logs -f app

# 서비스 삭제 (볼륨 유지)
docker-compose down

# 서비스 + 볼륨 삭제
docker-compose down -v

# 이미지 재빌드
docker-compose build --no-cache

# 상태 확인
docker-compose ps

# 리소스 사용량
docker-compose stats
```

### 6.2 Docker 명령어

```bash
# 실행 중인 컨테이너 목록
docker ps

# 모든 컨테이너 목록
docker ps -a

# 컨테이너 내부 접속
docker exec -it chat-postgres bash

# 컨테이너 로그
docker logs -f chat-app

# 컨테이너 중지
docker stop chat-app

# 컨테이너 삭제
docker rm chat-app

# 이미지 목록
docker images

# 이미지 삭제
docker rmi chat-app:latest

# 사용하지 않는 리소스 정리
docker system prune -a
```

### 6.3 PostgreSQL 명령어

```bash
# psql 접속
docker exec -it chat-postgres psql -U chatuser -d chatdb

# 테이블 목록
\dt

# 테이블 스키마
\d users

# 쿼리 실행
SELECT * FROM users;

# 종료
\q
```

### 6.4 Artemis 명령어

```bash
# Artemis CLI 접속
docker exec -it chat-artemis /var/lib/artemis-instance/bin/artemis

# 큐 목록 조회
docker exec chat-artemis /var/lib/artemis-instance/bin/artemis queue stat

# 브로커 상태
docker exec chat-artemis /var/lib/artemis-instance/bin/artemis producer --message-count 1 --destination test
```

---

## 7. 개발 워크플로우 권장 사항

### 7.1 일상적인 개발

```bash
# 아침: Docker 인프라 시작
docker-compose up -d postgres artemis redis

# 개발: IntelliJ/VS Code에서 Spring Boot 실행
./gradlew bootRun --args='--spring.profiles.active=docker'

# 퇴근: Docker 중지 (데이터 유지)
docker-compose stop
```

### 7.2 기능 개발 완료 후

```bash
# 1. 로컬 테스트
./gradlew test

# 2. Docker 전체 구성으로 테스트
docker-compose up --build -d

# 3. 통합 테스트
curl http://localhost:8080/actuator/health

# 4. 문제 없으면 커밋
git add .
git commit -m "Add new feature"
git push
```

### 7.3 배포 전 검증

```bash
# 1. 프로덕션 compose로 로컬 테스트
docker-compose -f docker-compose.prod.yml up -d

# 2. 부하 테스트 (선택)
# Apache Bench 예시
ab -n 1000 -c 10 http://localhost:8080/api/workspaces

# 3. 문제 없으면 서버 배포
```

---

## 8. 참고 자료

- [Docker 공식 문서](https://docs.docker.com/)
- [Docker Compose 문서](https://docs.docker.com/compose/)
- [Spring Boot Docker 가이드](https://spring.io/guides/topicals/spring-boot-docker/)
- [PostgreSQL Docker Hub](https://hub.docker.com/_/postgres)
- [ActiveMQ Artemis Docker Hub](https://hub.docker.com/r/apache/activemq-artemis)

---

**작성일**: 2025-11-21
**작성자**: Claude AI
**버전**: 1.0
