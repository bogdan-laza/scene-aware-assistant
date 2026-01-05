import { Component } from '@angular/core';
import { MatButton } from '@angular/material/button';
import { VisionService } from '../vision-service';

@Component({
  selector: 'app-detector-component',
  templateUrl: './detector-component.html',
  styleUrl: './detector-component.css',
  standalone: false
})

export class DetectorComponent {
  selected: string = '';
  imageFile: File | null = null;

  constructor(private service: VisionService) {}

  sendFrame() {
    if (this.imageFile == null)
      return;
    this.service.analyzeImage(this.imageFile, this.selected);
  }

  onFileSelected(file: File | null) {
    this.imageFile = file;
  }
}
