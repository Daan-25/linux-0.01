#include <stdio.h>	/* fprintf */
#include <stdlib.h>	/* contains exit */
#include <sys/types.h>	/* unistd.h needs this */
#include <unistd.h>	/* contains read/write */
#include <fcntl.h>
#include <stdint.h>

#define MINIX_HEADER 32
#define GCC_HEADER 1024

void die(char * str)
{
	fprintf(stderr,"%s\n",str);
	exit(1);
}

void usage(void)
{
	die("Usage: build boot system [> image]");
}

int main(int argc, char ** argv)
{
	int i,c,id;
	char buf[1024];
	int32_t *hdr;

	if (argc != 3)
		usage();
	for (i=0;i<sizeof buf; i++) buf[i]=0;
	if ((id=open(argv[1],O_RDONLY,0))<0)
		die("Unable to open 'boot'");
	if (read(id,buf,MINIX_HEADER) != MINIX_HEADER)
		die("Unable to read header of 'boot'");
	hdr = (int32_t *) buf;
	if ((hdr[0] & 0x00FFFFFF)!=0x00100301)
		die("Non-Minix header of 'boot'");
	if (hdr[1]!=MINIX_HEADER)
		die("Non-Minix header of 'boot'");
	if (hdr[3]!=0)
		die("Illegal data segment in 'boot'");
	if (hdr[4]!=0)
		die("Illegal bss in 'boot'");
	if (hdr[5] != 0)
		die("Non-Minix header of 'boot'");
	if (hdr[7] != 0)
		die("Illegal symbol table in 'boot'");
	i=read(id,buf,sizeof buf);
	fprintf(stderr,"Boot sector %d bytes.\n",i);
	if (i>510)
		die("Boot block may not exceed 510 bytes");
	buf[510]=0x55;
	buf[511]=0xAA;
	i=write(1,buf,512);
	if (i!=512)
		die("Write call failed");
	close (id);

	if ((id=open(argv[2],O_RDONLY,0))<0)
		die("Unable to open 'system'");
	for (i=0 ; (c=read(id,buf,sizeof buf))>0 ; i+=c )
		if (write(1,buf,c)!=c)
			die("Write call failed");
	close(id);
	fprintf(stderr,"System %d bytes.\n",i);
	return(0);
}
