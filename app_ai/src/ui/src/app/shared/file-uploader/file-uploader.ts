import { Component, ElementRef, EventEmitter, Output, signal, ViewChild } from '@angular/core';
import { MatSnackBar } from '@angular/material/snack-bar';
import { MatIcon } from '@angular/material/icon';

@Component({
  selector: 'app-file-uploader',
  templateUrl: './file-uploader.html',
  styleUrl: './file-uploader.css',
  standalone: false,
})

export class FileUploader {
  imageName = signal('');
  fileSize = signal(0);
  uploadProgress = signal(0);
  imagePreview = signal('');
  @ViewChild('fileInput') fileInput: ElementRef | undefined;
  selectedFile: File | null = null;
  uploadSuccess: boolean = false;
  uploadError: boolean = false;
  @Output() fileSelected = new EventEmitter<File | null>();

  constructor(private snackBar: MatSnackBar) {}

  onDrop(event: DragEvent) {
    event.preventDefault()
    const file = event.dataTransfer?.files[0] as File | null;
    this.uploadFile(file);
  }

  onDragOver(event: DragEvent) {
    event.preventDefault()
  }

  removeImage(): void {
    this.selectedFile = null;
    this.imageName.set('');
    this.fileSize.set(0);
    this.imagePreview.set('');
    this.uploadSuccess = false;
    this.uploadError = false;
    this.uploadProgress.set(0);
    this.fileSelected.emit(null);
  }

  uploadFile(file: File | null): void {
    if (file && file.type.startsWith('image/')) {
      this.selectedFile = file;
      this.fileSize.set(Math.round(file.size / 1024))

      const reader = new FileReader();
      reader.onload = (e) => {
        this.imagePreview.set(e.target?.result as string)
      };

      reader.readAsDataURL(file);

      this.uploadSuccess = true
      this.uploadError = false
      this.imageName.set(file.name)
    }
    else {
      this.uploadSuccess = false
      this.uploadError = true
      this.snackBar.open('Only image files are supported!', 'Close', {
        duration: 3000,
        panelClass: 'error'
      });
    }
  }

  onFileChange(event: any) {
    const file = event.target.files[0] as File | null;
    this.uploadFile(file);
  }

}
