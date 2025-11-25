# 클라우드 최소 비용 배포 가이드

> **목표**: 채팅 앱을 월 $5-20 이내로 운영하기
> **대상**: 개인 프로젝트, 스타트업 MVP, 소규모 서비스

---

## 📚 목차

1. [현재 구성 리소스 요구사항](#1-현재-구성-리소스-요구사항)
2. [클라우드 제공자별 비용 비교](#2-클라우드-제공자별-비용-비교)
3. [무료 티어 100% 활용 전략](#3-무료-티어-100-활용-전략)
4. [최소 비용 아키텍처](#4-최소-비용-아키텍처)
5. [추천 배포 시나리오](#5-추천-배포-시나리오)
6. [비용 절감 팁](#6-비용-절감-팁)

---

## 1. 현재 구성 리소스 요구사항

### 1.1 개발 환경 (docker-compose.yml)

```
서비스              CPU    메모리    디스크
────────────────────────────────────────
PostgreSQL         0.5    512MB     5GB
Artemis           0.5    1GB       1GB
Redis             0.5    512MB     1GB
Spring Boot       1.0    1GB       1GB
────────────────────────────────────────
합계              2.5    3GB       8GB
```

### 1.2 프로덕션 환경 (docker-compose.prod.yml)

```
서비스              CPU    메모리    디스크
────────────────────────────────────────
PostgreSQL         1.0    2GB       20GB
Artemis           1.0    2GB       5GB
Redis             0.5    1GB       2GB
Spring Boot x2    2.0    4GB       2GB
────────────────────────────────────────
합계              4.5    9GB       29GB
```

### 1.3 최소 사양 (단일 서버 올인원)

```
서비스              CPU    메모리    디스크
────────────────────────────────────────
모든 서비스 통합    2      4GB       20GB

💡 이 정도면 동시 접속자 100명까지 가능!
```

---

## 2. 클라우드 제공자별 비용 비교

### 2.1 해외 클라우드 (USD 기준, 2025년 1월)

#### AWS (Amazon Web Services)

| 서비스 | 스펙 | 월 비용 | 무료 티어 |
|-------|------|---------|----------|
| **EC2 t3.medium** | 2 vCPU, 4GB RAM | $30.37 | 12개월 (t2.micro) |
| **RDS PostgreSQL** | db.t3.micro | $15.33 | 12개월 (750시간) |
| **ElastiCache Redis** | cache.t3.micro | $12.41 | ❌ |
| **MQ (Artemis 대체)** | mq.t3.micro | $17.52 | ❌ |
| **합계** | | **$75.63/월** | |

**AWS 무료 티어 활용 시**: $0/월 (12개월)
- EC2 t2.micro (1 vCPU, 1GB RAM) - 750시간/월
- RDS db.t2.micro - 750시간/월
- S3 5GB
- **⚠️ 제한**: 메모리 부족 (Artemis 구동 어려움)

#### Google Cloud Platform (GCP)

| 서비스 | 스펙 | 월 비용 | 무료 티어 |
|-------|------|---------|----------|
| **Compute Engine e2-medium** | 2 vCPU, 4GB RAM | $24.27 | ✅ 평생 (e2-micro) |
| **Cloud SQL PostgreSQL** | db-f1-micro | $7.67 | ❌ |
| **Memorystore Redis** | 1GB | $36.50 | ❌ |
| **합계** | | **$68.44/월** | |

**GCP 무료 티어 (영구)**:
- Compute Engine e2-micro (1 vCPU, 1GB RAM) - $0/월 **평생**
- Cloud Storage 5GB
- **👍 장점**: 기간 제한 없음!

#### Azure

| 서비스 | 스펙 | 월 비용 | 무료 티어 |
|-------|------|---------|----------|
| **VM B2s** | 2 vCPU, 4GB RAM | $30.37 | 12개월 (B1s) |
| **Database for PostgreSQL** | Basic | $15.77 | ❌ |
| **Redis Cache** | C0 250MB | $16.06 | ❌ |
| **합계** | | **$62.20/월** | |

#### DigitalOcean (추천! 🌟)

| 플랜 | 스펙 | 월 비용 | 비고 |
|------|------|---------|------|
| **Basic Droplet** | 2 vCPU, 4GB RAM, 80GB SSD | **$24/월** | **간단하고 저렴!** |
| **+ Managed PostgreSQL** | 1GB | $15/월 | 선택사항 |
| **+ Managed Redis** | 1GB | $15/월 | 선택사항 |

**올인원 구성 (Droplet만)**: **$24/월** ⭐

### 2.2 국내 클라우드 (KRW 기준)

#### 네이버 클라우드

| 서비스 | 스펙 | 월 비용 | 무료 크레딧 |
|-------|------|---------|-----------|
| **Compact Server** | 2 vCPU, 4GB RAM | ₩30,000 | ✅ ₩100,000 (신규) |
| **Cloud DB PostgreSQL** | 2GB | ₩45,000 | ❌ |
| **합계** | | **₩75,000/월** | |

**무료 크레딧 활용**: 3개월 무료

#### 카카오 클라우드 (i Cloud)

| 서비스 | 스펙 | 월 비용 | 무료 크레딧 |
|-------|------|---------|-----------|
| **Virtual Machine** | 2 vCPU, 4GB RAM | ₩25,000 | ✅ ₩50,000 (신규) |
| **합계** | | **₩25,000/월** | |

#### NHN Cloud (Toast)

| 서비스 | 스펙 | 월 비용 | 무료 크레딧 |
|-------|------|---------|-----------|
| **Instance m2.c2m4** | 2 vCPU, 4GB RAM | ₩35,000 | ✅ ₩30,000 (신규) |
| **합계** | | **₩35,000/월** | |

### 2.3 초저비용 옵션

#### Oracle Cloud (진짜 무료!)

| 서비스 | 스펙 | 월 비용 | 비고 |
|-------|------|---------|------|
| **Always Free Compute** | 4 vCPU, 24GB RAM | **$0/월** | **평생 무료!** |
| **Autonomous DB** | 20GB | **$0/월** | **평생 무료!** |
| **Block Volume** | 200GB | **$0/월** | **평생 무료!** |

**⚠️ 단점**:
- 한국 리전 없음 (일본/싱가폴)
- 네트워크 속도 느림
- 관리 인터페이스 복잡

**👍 장점**:
- 완전 무료
- 스펙 좋음 (ARM 기반)

#### Fly.io (컨테이너 특화)

| 서비스 | 스펙 | 월 비용 | 무료 티어 |
|-------|------|---------|----------|
| **Machines** | 1 vCPU, 256MB | **$0/월** | ✅ 3개 무료 |
| **PostgreSQL** | 256MB | **$0/월** | ✅ 3GB 스토리지 |
| **합계** | | **$0/월** | |

**⚠️ 제한**:
- 메모리 작음 (Artemis 구동 어려움)
- 트래픽 100GB/월

#### Railway (개발자 친화적)

| 서비스 | 플랜 | 월 비용 | 무료 티어 |
|-------|------|---------|----------|
| **Hobby Plan** | 공유 리소스 | **$5/월** | ✅ $5 크레딧/월 |
| **PostgreSQL** | 포함 | 포함 | |
| **Redis** | 포함 | 포함 | |

**👍 장점**:
- Git 연동 자동 배포
- 간단한 설정

---

## 3. 무료 티어 100% 활용 전략

### 3.1 전략 1: 멀티 클라우드 (완전 무료)

```
┌─────────────────────────────────────┐
│  Google Cloud (무료 티어, 평생)      │
│  ├─ Compute Engine e2-micro         │
│  │  └─ Spring Boot App              │
│  └─ Cloud Storage 5GB               │
└─────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│  Supabase (무료)                    │
│  └─ PostgreSQL 500MB                │
└─────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│  Redis Cloud (무료)                 │
│  └─ Redis 30MB                      │
└─────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────┐
│  CloudAMQP (무료)                   │
│  └─ RabbitMQ (Artemis 대신)         │
└─────────────────────────────────────┘

💰 총 비용: $0/월 (평생)
👥 동시 접속: 20-30명
```

#### 서비스별 무료 티어

**PostgreSQL**:
- [Supabase](https://supabase.com): 500MB, 무제한 API 요청
- [Neon](https://neon.tech): 3GB, 서버리스
- [ElephantSQL](https://elephantsql.com): 20MB (작음)

**Redis**:
- [Redis Cloud](https://redis.com/try-free/): 30MB
- [Upstash](https://upstash.com): 10,000 req/day

**메시지 큐** (Artemis 대신):
- [CloudAMQP](https://cloudamqp.com): RabbitMQ 무료
- [CloudKarafka](https://cloudkarafka.com): Kafka 무료

### 3.2 전략 2: Oracle Cloud 올인원 (무료)

**구성**:
```bash
# 1. Oracle Cloud 가입
# https://cloud.oracle.com/free

# 2. Always Free Compute 생성
# VM.Standard.A1.Flex (ARM)
# - 4 OCPU (vCPU)
# - 24GB RAM
# - 200GB Storage

# 3. Docker Compose 전체 배포
docker-compose -f docker-compose.prod.yml up -d

# ✅ 완전 무료로 모든 서비스 실행 가능!
```

**장점**:
- 완전 무료 (평생)
- 스펙 좋음
- 단일 서버 관리

**단점**:
- 한국 리전 없음
- 네트워크 레이턴시 (~100ms)
- UI 복잡

### 3.3 전략 3: AWS 12개월 무료 (단기)

```
AWS 무료 티어 (12개월)
├─ EC2 t2.micro (1GB RAM)
│  └─ Spring Boot + Artemis (경량 설정)
├─ RDS db.t2.micro
│  └─ PostgreSQL
└─ ElasticCache 대신 Redis Stack (Docker)

⚠️ 주의: 12개월 후 과금 시작
```

---

## 4. 최소 비용 아키텍처

### 4.1 울트라 미니멀 (월 $5-10)

**Railway 배포 (권장)**:

```yaml
# railway.json
{
  "services": [
    {
      "name": "app",
      "source": {
        "repo": "your-repo"
      },
      "plan": "hobby"
    },
    {
      "name": "postgres",
      "plan": "hobby"
    }
  ]
}
```

**구성**:
- ✅ PostgreSQL (Railway 제공)
- ✅ Spring Boot App
- ❌ Artemis → **WebSocket만 사용** (JMS 제거)
- ❌ Redis → **Caffeine Cache만 사용**

**코드 수정**:
```yaml
# application-minimal.yml
spring:
  datasource:
    url: ${DATABASE_URL}  # Railway 자동 주입

# JMS 비활성화
spring.artemis.mode: embedded
spring.jms.enabled: false

# 캐시는 Caffeine만
spring.cache.type: caffeine
```

**비용**: $5/월

### 4.2 단일 서버 올인원 (월 $10-20)

**DigitalOcean Droplet (권장)**:

```bash
# 1. Droplet 생성 ($12/월)
# - Ubuntu 22.04
# - 2 vCPU, 2GB RAM, 50GB SSD

# 2. Docker 설치
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# 3. 저사양 docker-compose 사용
docker-compose -f docker-compose.minimal.yml up -d
```

**docker-compose.minimal.yml**:
```yaml
services:
  postgres:
    image: postgres:15-alpine
    environment:
      POSTGRES_DB: chatdb
      POSTGRES_USER: chatuser
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    deploy:
      resources:
        limits:
          memory: 512M  # 제한
    restart: unless-stopped

  app:
    build: .
    environment:
      SPRING_PROFILES_ACTIVE: minimal
      SPRING_DATASOURCE_URL: jdbc:postgresql://postgres:5432/chatdb
      # Artemis 임베디드 모드
      SPRING_ARTEMIS_MODE: embedded
    ports:
      - "80:8080"
    depends_on:
      - postgres
    deploy:
      resources:
        limits:
          memory: 1G
    restart: unless-stopped
```

**비용**: $12/월

### 4.3 중간 단계 (월 $20-30)

**구성**:
- DigitalOcean Droplet: $24/월 (2 vCPU, 4GB RAM)
- 모든 서비스 Docker로 실행
- 백업 활성화: +$2/월

**특징**:
- 동시 접속 100-200명
- 안정적 운영
- 확장 가능

---

## 5. 추천 배포 시나리오

### 시나리오 1: MVP/테스트 (완전 무료)

**대상**: 개인 프로젝트, 포트폴리오

**구성**:
```
Google Cloud e2-micro (무료, 평생)
├─ Spring Boot App
├─ PostgreSQL (Supabase 무료)
└─ Redis (Redis Cloud 무료)
```

**비용**: **$0/월**

**제한**:
- 동시 접속 20-30명
- 메모리 1GB (Artemis 사용 어려움)

**배포 스크립트**:
```bash
#!/bin/bash
# deploy-free.sh

# 1. GCP e2-micro 인스턴스 생성
gcloud compute instances create chat-app \
  --machine-type=e2-micro \
  --zone=us-west1-a \
  --image-family=ubuntu-2204-lts

# 2. Spring Boot만 배포 (경량 모드)
./gradlew bootJar
scp build/libs/*.jar gcp:/app/

# 3. 환경 변수 설정
export DATABASE_URL="postgresql://supabase-host/db"
export REDIS_URL="redis://redis-cloud-host"

# 4. 실행
java -Xmx512m -jar app.jar --spring.profiles.active=minimal
```

### 시나리오 2: 소규모 서비스 ($10-20/월)

**대상**: 친구들과 사용, 소규모 팀

**구성**:
```
Railway ($5/월)
├─ Spring Boot App
├─ PostgreSQL (포함)
└─ Redis (포함)
```

**또는**:

```
DigitalOcean Droplet ($12/월)
└─ Docker Compose 전체
```

**비용**: **$5-12/월**

**배포**:
```bash
# Railway
railway login
railway init
railway up

# 또는 DigitalOcean
doctl compute droplet create chat-app \
  --image ubuntu-22-04-x64 \
  --size s-2vcpu-2gb \
  --region sgp1

# SSH 접속 후
git clone https://github.com/your-repo/simple-chat-app.git
cd simple-chat-app
docker-compose -f docker-compose.minimal.yml up -d
```

### 시나리오 3: 실제 서비스 ($24-30/월)

**대상**: 100-200명 사용자, 안정적 운영

**구성**:
```
DigitalOcean Droplet ($24/월)
├─ PostgreSQL (Docker)
├─ Artemis (Docker)
├─ Redis (Docker)
└─ Spring Boot x2 (Docker)

+ 백업 ($2/월)
+ 모니터링 (Grafana Cloud 무료)
```

**비용**: **$26/월**

**배포**:
```bash
# 1. Droplet 생성 (4GB RAM)
doctl compute droplet create chat-app-prod \
  --image ubuntu-22-04-x64 \
  --size s-2vcpu-4gb \
  --region sgp1 \
  --enable-backups

# 2. 프로젝트 배포
ssh root@your-droplet-ip
git clone https://github.com/your-repo/simple-chat-app.git
cd simple-chat-app

# 3. 환경 변수 설정
cp .env.example .env
nano .env  # 실제 값 입력

# 4. 실행
docker-compose -f docker-compose.prod.yml up -d

# 5. 모니터링 설정
docker run -d --name prometheus prom/prometheus
```

---

## 6. 비용 절감 팁

### 6.1 아키텍처 최적화

#### 1. Artemis 제거 (메모리 -1GB)

**대안**: WebSocket만 사용

```kotlin
// JMS 없이 직접 브로드캐스트
@MessageMapping("/chat/send/{channelId}")
fun sendMessage(
    @DestinationVariable channelId: String,
    message: ChatMessageDTO
) {
    // DB 저장
    messageRepository.save(message)

    // 직접 WebSocket 전송
    messagingTemplate.convertAndSend("/topic/channel/$channelId", message)
}
```

**절감**: 메모리 1GB, 약 $5-10/월

#### 2. Redis 제거 (메모리 -512MB)

**대안**: Caffeine Cache만 사용

```yaml
spring:
  cache:
    type: caffeine
    caffeine:
      spec: maximumSize=1000,expireAfterWrite=10m
```

**절감**: 메모리 512MB, 약 $3-5/월

#### 3. PostgreSQL 최적화

```yaml
# docker-compose.minimal.yml
postgres:
  command: >
    postgres
    -c max_connections=20          # 기본 100 → 20
    -c shared_buffers=128MB        # 기본 128MB
    -c effective_cache_size=256MB
    -c maintenance_work_mem=64MB
    -c checkpoint_completion_target=0.9
    -c wal_buffers=4MB
    -c default_statistics_target=100
    -c random_page_cost=1.1
```

**절감**: 메모리 ~200MB

### 6.2 Managed Service vs Self-hosted

| 서비스 | Self-hosted | Managed | 절감 |
|--------|-------------|---------|------|
| PostgreSQL | Docker (무료) | AWS RDS $15/월 | $15/월 |
| Redis | Docker (무료) | ElastiCache $12/월 | $12/월 |
| Artemis | Docker (무료) | AWS MQ $18/월 | $18/월 |
| **합계** | **$0/월** | **$45/월** | **$45/월** |

**결론**: 소규모는 Self-hosted가 압도적으로 저렴!

### 6.3 리전 선택

| 리전 | 레이턴시 (한국) | 비용 | 추천 |
|------|----------------|------|------|
| **서울 (Seoul)** | 5ms | 비쌈 (+30%) | ✅ 한국 사용자 |
| **도쿄 (Tokyo)** | 35ms | 중간 | ✅ 아시아 |
| **싱가폴 (Singapore)** | 70ms | 중간 | ✅ 아시아 |
| **미국 서부 (US-West)** | 150ms | 저렴 | 글로벌 |
| **미국 동부 (US-East)** | 200ms | 저렴 | 글로벌 |

**팁**: 한국 사용자 대상이면 도쿄/싱가폴이 가성비 좋음

### 6.4 스팟 인스턴스 (AWS)

```bash
# 일반 인스턴스 대비 70% 저렴
# 단, 언제든 종료될 수 있음

aws ec2 request-spot-instances \
  --instance-count 1 \
  --type "persistent" \
  --launch-specification file://spec.json
```

**절감**: 70% (예: $30 → $9)

**주의**: 갑작스런 종료 대비 필요

### 6.5 예약 인스턴스 (장기 운영)

1년 약정 시:
- AWS: 30% 할인
- GCP: 57% 할인
- Azure: 40% 할인

### 6.6 자동 스케일링 비활성화

개발 단계에서는:
```yaml
deploy:
  replicas: 1  # 2 → 1
```

**절감**: 50%

---

## 7. 최종 추천

### 당신에게 맞는 선택은?

```
┌─────────────────────────────────────────┐
│ 완전 무료로 시작하고 싶다면?             │
│ → Oracle Cloud Always Free             │
│    또는 멀티 클라우드 조합              │
│    비용: $0/월                          │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│ 간단하게 배포하고 싶다면?               │
│ → Railway.app                           │
│    비용: $5/월                          │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│ 안정적으로 운영하고 싶다면?             │
│ → DigitalOcean Droplet                  │
│    비용: $12-24/월                      │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│ 확장 가능하게 시작하고 싶다면?          │
│ → AWS/GCP (무료 티어 12개월)           │
│    비용: $0 → $30/월                    │
└─────────────────────────────────────────┘
```

### 단계별 전략

```
[1단계] MVP/테스트 (0-3개월)
→ Oracle Cloud 무료
   또는 Railway $5/월

[2단계] 베타 서비스 (3-6개월)
→ DigitalOcean $12/월
   동시 접속 50-100명

[3단계] 정식 서비스 (6개월+)
→ DigitalOcean $24/월
   또는 AWS/GCP 본격 사용
   동시 접속 200-500명

[4단계] 스케일업
→ Kubernetes + Managed Services
   또는 멀티 리전 배포
```

---

## 부록: 비용 계산 스프레드시트

### 시나리오별 월 비용 비교

| 구성 | 인프라 | 비용/월 | 동시 접속 | 추천 대상 |
|------|-------|---------|----------|----------|
| **울트라 미니멀** | Railway | $5 | 20-30명 | 개인, 테스트 |
| **경량** | DO $12 | $12 | 50-100명 | 소규모 팀 |
| **표준** | DO $24 | $24 | 100-200명 | 스타트업 |
| **프로덕션** | AWS/GCP | $50-100 | 500-1000명 | 본격 서비스 |
| **엔터프라이즈** | K8s 클러스터 | $200+ | 5000명+ | 대기업 |

### 트래픽별 예상 비용

```
동시 접속자 수    월 비용        구성
─────────────────────────────────────
20-30명          $0-5          무료 티어
50-100명         $10-15        단일 서버 (2GB)
100-200명        $20-30        단일 서버 (4GB)
200-500명        $50-80        이중화 서버
500-1000명       $100-200      오토스케일링
1000명+          $200+         K8s 클러스터
```

---

**작성일**: 2025-11-21
**작성자**: Claude AI
**버전**: 1.0
