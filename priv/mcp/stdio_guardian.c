/* Owned MCP stdio bridge. Target stdout is DATA, never a guardian control frame.
 * The same single-process, fork-denied Seatbelt boundary as L14 is mandatory.
 */
#define _DARWIN_C_SOURCE 1
#include <sandbox.h>
#include <sys/types.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <poll.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

#define INPUT_CAP 1048576
static volatile sig_atomic_t interrupted, wall_expired, owned_target;
static long long write_deadline;
static void kill_owned(void) {
  pid_t p=(pid_t)owned_target;
  if(p>1){(void)kill(-p,SIGKILL);(void)kill(p,SIGKILL);}
}
static void interrupted_by(int sig) {
  if(sig==SIGALRM)wall_expired=1;else interrupted=1;
  kill_owned();
}
static long long now_ms(void) {
  struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);
  return (long long)t.tv_sec*1000+t.tv_nsec/1000000;
}
static int write_all(int fd,const void *data,size_t n) {
  const char *p=data;
  while(n){ssize_t w=write(fd,p,n);
    if(w<0&&errno==EINTR)continue;
    if(w<0&&(errno==EAGAIN||errno==EWOULDBLOCK)){
      if(write_deadline&&now_ms()>=write_deadline)return -1;
      struct pollfd out={fd,POLLOUT,0};(void)poll(&out,1,10);continue;
    }
    if(w<=0)return -1;p+=w;n-=(size_t)w;
  }return 0;
}
static int frame(unsigned char type,const void *data,size_t n) {
  unsigned char h[5]={type,(unsigned char)(n>>24),(unsigned char)(n>>16),(unsigned char)(n>>8),(unsigned char)n};
  return write_all(STDOUT_FILENO,h,5)<0?-1:write_all(STDOUT_FILENO,data,n);
}
static void child_error(int fd,int stage) {
  int e[2]={stage,errno};(void)write_all(fd,e,sizeof(e));_exit(126);
}
static void limit(int resource,rlim_t n,int fd) {
  struct rlimit r={n,n};if(setrlimit(resource,&r)<0)child_error(fd,2);
}
static long long integer(const char *s,long long min,long long max) {
  char *end=NULL;errno=0;long long n=strtoll(s,&end,10);
  if(errno||!end||*end||n<min||n>max)return -1;return n;
}
static char *read_profile(const char *path) {
  int fd=open(path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return NULL;
  struct stat st;if(fstat(fd,&st)<0||!S_ISREG(st.st_mode)||st.st_size<1||st.st_size>262144||st.st_uid!=getuid()||(st.st_mode&0077)){close(fd);return NULL;}
  char *text=calloc((size_t)st.st_size+1,1);if(!text){close(fd);return NULL;}
  size_t n=0;while(n<(size_t)st.st_size){ssize_t r=read(fd,text+n,(size_t)st.st_size-n);
    if(r<0&&errno==EINTR)continue;if(r<=0){free(text);close(fd);return NULL;}n+=(size_t)r;
  }close(fd);return text;
}
static void setup_failure(const char *reason) {
  char msg[400];int n=snprintf(msg,sizeof(msg),"{\"setup_error\":\"%s\",\"target_exited\":true,\"target_pid\":null}",reason);
  (void)frame(2,msg,(size_t)n);
}
static int nonblock(int fd){return fcntl(fd,F_SETFL,O_NONBLOCK);}
int main(int argc,char **argv) {
  /* bridge PROFILE CWD TMP WALL_MS CPU_SECONDS FILE_BYTES OUTPUT_BYTES CMD ARGS */
  if(argc<9){setup_failure("invalid_native_arguments");return 64;}
  long long wall=integer(argv[4],1,3600000),cpu=integer(argv[5],1,60),file=integer(argv[6],1,1073741824),output=integer(argv[7],1,16777216);
  if(wall<0||cpu<0||file<0||output<0||argv[8][0]!='/'){setup_failure("invalid_native_limits");return 64;}
  signal(SIGPIPE,SIG_IGN);signal(SIGINT,interrupted_by);signal(SIGTERM,interrupted_by);signal(SIGHUP,interrupted_by);signal(SIGALRM,interrupted_by);
  char *profile=read_profile(argv[1]);if(!profile){setup_failure("invalid_private_profile");return 65;}
  int in[2],out[2],err[2],ack[2];
  if(pipe(in)||pipe(out)||pipe(err)||pipe(ack)){free(profile);setup_failure("pipe_failed");return 66;}
  (void)fcntl(ack[1],F_SETFD,FD_CLOEXEC);
  long long started=now_ms();pid_t target=fork();
  if(target<0){free(profile);setup_failure("fork_failed");return 67;}
  if(target==0){
    close(in[1]);close(out[0]);close(err[0]);close(ack[0]);
    if(setsid()<0)child_error(ack[1],1);
    if(dup2(in[0],0)<0||dup2(out[1],1)<0||dup2(err[1],2)<0)child_error(ack[1],1);
    int keep=ack[1],top=getdtablesize();for(int fd=3;fd<top;fd++)if(fd!=keep)close(fd);
    if(chdir(argv[2])<0)child_error(keep,1);
    limit(RLIMIT_CORE,0,keep);limit(RLIMIT_CPU,(rlim_t)cpu,keep);limit(RLIMIT_FSIZE,(rlim_t)file,keep);limit(RLIMIT_NOFILE,64,keep);limit(RLIMIT_STACK,8*1024*1024,keep);
    signal(SIGPIPE,SIG_DFL);signal(SIGINT,SIG_DFL);signal(SIGTERM,SIG_DFL);signal(SIGHUP,SIG_DFL);signal(SIGALRM,SIG_DFL);
    char *sandbox_error=NULL;if(sandbox_init(profile,0,&sandbox_error)!=0){if(sandbox_error)sandbox_free_error(sandbox_error);child_error(keep,3);}
    char tmp[PATH_MAX+8];if(snprintf(tmp,sizeof(tmp),"TMPDIR=%s",argv[3])>=(int)sizeof(tmp))child_error(keep,1);
    char *env[]={"LANG=C","LC_ALL=C","PATH=/usr/bin:/bin",tmp,NULL};
    execve(argv[8],&argv[8],env);child_error(keep,4);
  }
  free(profile);close(in[0]);close(out[1]);close(err[1]);close(ack[1]);
  owned_target=target;write_deadline=started+wall+2000;
  (void)nonblock(0);(void)nonblock(1);(void)nonblock(in[1]);(void)nonblock(out[0]);(void)nonblock(err[0]);(void)nonblock(ack[0]);
  struct itimerval timer={0};timer.it_value.tv_sec=wall/1000;timer.it_value.tv_usec=(wall%1000)*1000;
  if(setitimer(ITIMER_REAL,&timer,NULL)<0)interrupted=1;
  unsigned char *control=malloc(INPUT_CAP+5),*pending=malloc(INPUT_CAP);
  if(!control||!pending)interrupted=1;
  size_t cn=0,pn=0,po=0,observed=0,captured=0;
  int status=0,reaped=0,ack_open=1,out_open=1,err_open=1,in_open=1,input_closing=0,ready=0,setup_stage=0,setup_errno=0;
  long long killed_at=0;const char *reason="exited";struct rusage usage={0};unsigned char buffer[8192];
  for(;;){
    if(!killed_at&&(interrupted||wall_expired||now_ms()-started>=wall)){
      reason=wall_expired?"wall_time":interrupted?"cancelled":"wall_time";killed_at=now_ms();kill_owned();
    }
    struct pollfd fds[5]={{0,POLLIN|POLLHUP,0},{out[0],POLLIN|POLLHUP,0},{err[0],POLLIN|POLLHUP,0},{ack[0],POLLIN|POLLHUP,0},{in[1],POLLOUT|POLLHUP,0}};
    if(!out_open)fds[1].fd=-1;if(!err_open)fds[2].fd=-1;if(!ack_open)fds[3].fd=-1;if(!in_open||pn==po)fds[4].fd=-1;
    int polled=poll(fds,5,10);if(polled<0&&errno!=EINTR){interrupted=1;continue;}
    if(!killed_at&&(fds[0].revents&(POLLIN|POLLHUP|POLLERR))){
      ssize_t n=read(0,control+cn,INPUT_CAP+5-cn);
      if(n==0){reason="owner_lost";killed_at=now_ms();kill_owned();}
      else if(n>0){cn+=(size_t)n;
        while(cn>=5){size_t len=((size_t)control[1]<<24)|((size_t)control[2]<<16)|((size_t)control[3]<<8)|control[4];
          if(len>INPUT_CAP){interrupted=1;break;}if(cn<len+5)break;
          unsigned char type=control[0];
          if(type==1&&in_open&&!input_closing){
            if(po){memmove(pending,pending+po,pn-po);pn-=po;po=0;}
            if(len>INPUT_CAP-pn){interrupted=1;break;}memcpy(pending+pn,control+5,len);pn+=len;
          }else if(type==2&&len==0){input_closing=1;}
          else if(type==3&&len==0){reason="cancelled";killed_at=now_ms();kill_owned();}
          else {interrupted=1;break;}
          memmove(control,control+len+5,cn-len-5);cn-=len+5;
        }
        if(cn==INPUT_CAP+5)interrupted=1;
      }else if(errno!=EAGAIN&&errno!=EWOULDBLOCK&&errno!=EINTR)interrupted=1;
    }
    if(in_open&&pn>po&&(fds[4].revents&(POLLOUT|POLLHUP|POLLERR))){
      ssize_t n=write(in[1],pending+po,pn-po);if(n>0){po+=(size_t)n;if(po==pn)po=pn=0;}
      else if(n<0&&errno!=EAGAIN&&errno!=EWOULDBLOCK&&errno!=EINTR){close(in[1]);in_open=0;}
    }
    /* Flush already accepted notifications before presenting EOF to the MCP
     * server. Otherwise close could silently discard timeout cancellation. */
    if(in_open&&input_closing&&pn==po){close(in[1]);in_open=0;}
    if(ack_open&&(fds[3].revents&(POLLIN|POLLHUP|POLLERR))){
      int e[2]={0};ssize_t n=read(ack[0],e,sizeof(e));
      if(n>0){setup_stage=e[0];setup_errno=e[1];reason="setup_error";}
      if(n>=0){ack_open=0;close(ack[0]);if(n==0&&!killed_at){
        char message[256];int len=snprintf(message,sizeof(message),"{\"guardian_pid\":%d,\"target_pid\":%d,\"process_group\":%d,\"profile_applied\":true,\"exec_acknowledged\":true}",getpid(),target,target);
        if(frame(0,message,(size_t)len)<0)interrupted=1;ready=1;
      }}
    }
    for(int stream=0;stream<2;stream++){
      int fd=stream?err[0]:out[0];int *open_flag=stream?&err_open:&out_open;
      if(*open_flag&&(fds[stream+1].revents&(POLLIN|POLLHUP|POLLERR))){
        ssize_t n=read(fd,buffer,sizeof(buffer));if(n>0){observed+=(size_t)n;size_t take=(size_t)n;
          if(take>(size_t)output-captured)take=(size_t)output-captured;
          if(take&&frame(stream?3:1,buffer,take)<0)interrupted=1;captured+=take;
          if(observed>(size_t)output&&!killed_at){reason="output_limit";killed_at=now_ms();kill_owned();}
        }else if(n==0){*open_flag=0;close(fd);}
      }
    }
    if(!reaped){
      sigset_t block,previous;sigemptyset(&block);sigaddset(&block,SIGINT);sigaddset(&block,SIGTERM);sigaddset(&block,SIGHUP);sigaddset(&block,SIGALRM);
      (void)sigprocmask(SIG_BLOCK,&block,&previous);pid_t waited=wait4(target,&status,WNOHANG,&usage);
      if(waited==target){reaped=1;owned_target=0;}(void)sigprocmask(SIG_SETMASK,&previous,NULL);
    }
    if(reaped&&!out_open&&!err_open&&!ack_open)break;
    if(killed_at&&now_ms()-killed_at>2000){reason="cleanup_timeout";break;}
  }
  if(in_open)close(in[1]);free(control);free(pending);
  memset(&timer,0,sizeof(timer));(void)setitimer(ITIMER_REAL,&timer,NULL);
  int group_gone=(kill(-target,0)<0&&errno==ESRCH),code=reaped&&WIFEXITED(status)?WEXITSTATUS(status):-1,sig=reaped&&WIFSIGNALED(status)?WTERMSIG(status):0;
  char final[1000];int len=snprintf(final,sizeof(final),"{\"reason\":\"%s\",\"target_pid\":%d,\"guardian_pid\":%d,\"target_exited\":%s,\"process_group_gone\":%s,\"exit_status\":%d,\"signal\":%d,\"output_bytes\":%zu,\"captured_bytes\":%zu,\"duration_ms\":%lld,\"cpu_ms\":%lld,\"setup_stage\":%d,\"setup_errno\":%d,\"exec_acknowledged\":%s,\"fd_limit\":64,\"fork_policy\":\"deny\"}",reason,target,getpid(),reaped?"true":"false",group_gone?"true":"false",code,sig,observed,captured,now_ms()-started,(long long)(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)*1000+(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1000,setup_stage,setup_errno,ready?"true":"false");
  (void)frame(2,final,(size_t)len);return reaped&&group_gone?0:70;
}
